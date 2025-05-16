#!/bin/bash

set -euo pipefail

function createPostgresConfig() {
  cp /etc/postgresql/$PG_VERSION/main/postgresql.custom.conf.tmpl /etc/postgresql/$PG_VERSION/main/conf.d/postgresql.custom.conf
  sudo -u postgres echo "autovacuum = $AUTOVACUUM" >> /etc/postgresql/$PG_VERSION/main/conf.d/postgresql.custom.conf
  cat /etc/postgresql/$PG_VERSION/main/conf.d/postgresql.custom.conf
}

function setPostgresPassword() {
    sudo -u postgres psql -c "ALTER USER renderer PASSWORD '${PGPASSWORD:-renderer}'"
}

if [ "$#" -ne 1 ]; then
    echo "usage: <import|run>"
    echo "commands:"
    echo "    import: Set up the database and import $MAIN_PBF"
    echo "    run: Runs Apache and renderd to serve tiles at /tile/{z}/{x}/{y}.png"
    echo "environment variables:"
    echo "    THREADS: defines number of threads used for importing / tile rendering"
    echo "    UPDATES: consecutive updates (enabled/disabled)"
    echo "    NAME_LUA: name of .lua script to run as part of the style"
    echo "    NAME_STYLE: name of the .style to use"
    echo "    NAME_MML: name of the .mml file to render to mapnik.xml"
    echo "    NAME_SQL: name of the .sql file to use"
    exit 1
fi

set -x

# If /data/style is empty (e.g., fresh volume), copy in the default style from backup
if [ ! "$(ls -A /data/style/ 2>/dev/null)" ]; then
    echo "INFO: /data/style is empty – copying default openstreetmap-carto style..."
    cp -r /home/renderer/src/openstreetmap-carto-backup/* /data/style/
fi

# Build mapnik.xml only if it doesn't already exist
if [ ! -f /data/style/mapnik.xml ]; then
    echo "INFO: Generating mapnik.xml from project.mml using carto..."
    cd /data/style/
    carto ${NAME_MML:-project.mml} > mapnik.xml
fi

if [ "$1" == "import" ]; then
    # Ensure that database directory is in right state
    mkdir -p /data/database/postgres/
    chown renderer: /data/database/
    chown -R postgres: /var/lib/postgresql /data/database/postgres/
    if [ ! -f /data/database/postgres/PG_VERSION ]; then
        sudo -u postgres /usr/lib/postgresql/$PG_VERSION/bin/pg_ctl -D /data/database/postgres/ initdb -o "--locale C.UTF-8"
    fi

    # Initialize PostgreSQL
    createPostgresConfig
    service postgresql start
# create role only if it doesn't exist
sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='renderer'" | \
  grep -q 1 || sudo -u postgres createuser renderer

# create database only if it doesn't exist
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='gis'" | \
  grep -q 1 || sudo -u postgres createdb -E UTF8 -O renderer gis

# make sure required extensions are present (safe to re-run)
sudo -u postgres psql -d gis -c "CREATE EXTENSION IF NOT EXISTS postgis;"
sudo -u postgres psql -d gis -c "CREATE EXTENSION IF NOT EXISTS hstore;"
    sudo -u postgres psql -d gis -c "CREATE EXTENSION IF NOT EXISTS hstore;"
    sudo -u postgres psql -d gis -c "ALTER TABLE geometry_columns OWNER TO renderer;"
    sudo -u postgres psql -d gis -c "ALTER TABLE spatial_ref_sys OWNER TO renderer;"
    setPostgresPassword

  ###############################################################################
# Download Daylight Global Data
###############################################################################

# ── Settings ────────────────────────────────────────────────────────────────
DAYLIGHT_RELEASE="${DAYLIGHT_RELEASE:-1.58}"
BASE_URL="https://daylight-map-distribution.s3.us-west-1.amazonaws.com/release/v${DAYLIGHT_RELEASE}"

FILES=(
  "planet-v${DAYLIGHT_RELEASE}.osm.pbf"
  "ml-buildings-v${DAYLIGHT_RELEASE}.osm.pbf"
  "fb-ml-roads-v${DAYLIGHT_RELEASE}.osc.gz"
  "admin-v${DAYLIGHT_RELEASE}.osc.gz"
  "coastlines-v${DAYLIGHT_RELEASE}.tgz"
  "preferred-localization-v${DAYLIGHT_RELEASE}.tsv"
  "important-features-v${DAYLIGHT_RELEASE}.json"
)
MAIN_PBF="/data/planet-v${DAYLIGHT_RELEASE}.osm.pbf"

# ── Download loop ───────────────────────────────────────────────────────────
for FILE in "${FILES[@]}"; do
  DEST="/data/${FILE}"
  if [ ! -f "$DEST" ]; then
    echo "INFO: $FILE not found – downloading from Daylight..."
    wget ${WGET_ARGS:-} "${BASE_URL}/${FILE}" -O "$DEST"
  else
    echo "INFO: $FILE already exists – skipping download."
  fi
done

###############################################################################
# ➊ Combine Daylight planet with FB-ML Roads + Admin diffs
###############################################################################

# output name so the original file is left untouched
MERGED_PBF="/data/planet-v${DAYLIGHT_RELEASE}-merged.osm.pbf"

if [ ! -f "$MERGED_PBF" ]; then
    echo "INFO: Applying FB-ML road and admin .osc.gz updates…"
    # osmium can read .osc.gz directly; order does not matter for non-overlapping diffs
    osmium apply-changes \
        -o "$MERGED_PBF" \
        --flush-after=5000 \
        "$MAIN_PBF" \
        "/data/fb-ml-roads-v${DAYLIGHT_RELEASE}.osc.gz" \
        "/data/admin-v${DAYLIGHT_RELEASE}.osc.gz"
    echo "INFO: Merged planet written to $(basename "$MERGED_PBF")"
else
    echo "INFO: $(basename "$MERGED_PBF") already exists – skipping merge."
fi

# from here on, use the merged file everywhere
MAIN_PBF="$MERGED_PBF"

    if [ "${UPDATES:-}" == "enabled" ] || [ "${UPDATES:-}" == "1" ]; then
        # determine and set osmosis_replication_timestamp (for consecutive updates)
        REPLICATION_TIMESTAMP=`osmium fileinfo -g header.option.osmosis_replication_timestamp $MAIN_PBF`

        # initial setup of osmosis workspace (for consecutive updates)
        sudo -E -u renderer openstreetmap-tiles-update-expire.sh $REPLICATION_TIMESTAMP
    fi

    # copy polygon file if available
    if [ -f /data/region.poly ]; then
        cp /data/region.poly /data/database/region.poly
        chown renderer: /data/database/region.poly
    fi

    # flat-nodes
    if [ "${FLAT_NODES:-}" == "enabled" ] || [ "${FLAT_NODES:-}" == "1" ]; then
        OSM2PGSQL_EXTRA_ARGS="${OSM2PGSQL_EXTRA_ARGS:-} --flat-nodes /data/database/flat_nodes.bin"
    fi

    # Import data
    sudo -u renderer osm2pgsql -d gis --create --slim -G --hstore  \
      --tag-transform-script /data/style/${NAME_LUA:-openstreetmap-carto.lua}  \
      --number-processes ${THREADS:-4}  \
      -S /data/style/${NAME_STYLE:-openstreetmap-carto.style}  \
      $MAIN_PBF  \
      ${OSM2PGSQL_EXTRA_ARGS:-}  \
    ;

    # old flat-nodes dir
    if [ -f /nodes/flat_nodes.bin ] && ! [ -f /data/database/flat_nodes.bin ]; then
        mv /nodes/flat_nodes.bin /data/database/flat_nodes.bin
        chown renderer: /data/database/flat_nodes.bin
    fi

    # Create indexes
    if [ -f /data/style/${NAME_SQL:-indexes.sql} ]; then
        sudo -u postgres psql -d gis -f /data/style/${NAME_SQL:-indexes.sql}
    fi

    #Import external data
    chown -R renderer: /home/renderer/src/ /data/style/
    if [ -f /data/style/scripts/get-external-data.py ] && [ -f /data/style/external-data.yml ]; then
        sudo -E -u renderer python3 /data/style/scripts/get-external-data.py -c /data/style/external-data.yml -D /data/style/data
    fi

    # Register that data has changed for mod_tile caching purposes
    sudo -u renderer touch /data/database/planet-import-complete

    service postgresql stop

    exit 0
fi

if [ "$1" == "run" ]; then
    # Clean /tmp
    rm -rf /tmp/*

    # migrate old files
    if [ -f /data/database/PG_VERSION ] && ! [ -d /data/database/postgres/ ]; then
        mkdir /data/database/postgres/
        mv /data/database/* /data/database/postgres/
    fi
    if [ -f /nodes/flat_nodes.bin ] && ! [ -f /data/database/flat_nodes.bin ]; then
        mv /nodes/flat_nodes.bin /data/database/flat_nodes.bin
    fi
    if [ -f /data/tiles/data.poly ] && ! [ -f /data/database/region.poly ]; then
        mv /data/tiles/data.poly /data/database/region.poly
    fi

    # sync planet-import-complete file
    if [ -f /data/tiles/planet-import-complete ] && ! [ -f /data/database/planet-import-complete ]; then
        cp /data/tiles/planet-import-complete /data/database/planet-import-complete
    fi
    if ! [ -f /data/tiles/planet-import-complete ] && [ -f /data/database/planet-import-complete ]; then
        cp /data/database/planet-import-complete /data/tiles/planet-import-complete
    fi

    # Fix postgres data privileges
    chown -R postgres: /var/lib/postgresql/ /data/database/postgres/

    # Configure Apache CORS
    if [ "${ALLOW_CORS:-}" == "enabled" ] || [ "${ALLOW_CORS:-}" == "1" ]; then
        echo "export APACHE_ARGUMENTS='-D ALLOW_CORS'" >> /etc/apache2/envvars
    fi

    # Initialize PostgreSQL and Apache
    createPostgresConfig
    service postgresql start
    service apache2 restart
    setPostgresPassword

    # Configure renderd threads
    sed -i -E "s/num_threads=[0-9]+/num_threads=${THREADS:-4}/g" /etc/renderd.conf

    # start cron job to trigger consecutive updates
    if [ "${UPDATES:-}" == "enabled" ] || [ "${UPDATES:-}" == "1" ]; then
        /etc/init.d/cron start
        sudo -u renderer touch /var/log/tiles/run.log; tail -f /var/log/tiles/run.log >> /proc/1/fd/1 &
        sudo -u renderer touch /var/log/tiles/osmosis.log; tail -f /var/log/tiles/osmosis.log >> /proc/1/fd/1 &
        sudo -u renderer touch /var/log/tiles/expiry.log; tail -f /var/log/tiles/expiry.log >> /proc/1/fd/1 &
        sudo -u renderer touch /var/log/tiles/osm2pgsql.log; tail -f /var/log/tiles/osm2pgsql.log >> /proc/1/fd/1 &

    fi

    # Run while handling docker stop's SIGTERM
    stop_handler() {
        kill -TERM "$child"
    }
    trap stop_handler SIGTERM

    sudo -u renderer renderd -f -c /etc/renderd.conf &
    child=$!
    wait "$child"

    service postgresql stop

    exit 0
fi

echo "invalid command"
exit 1
