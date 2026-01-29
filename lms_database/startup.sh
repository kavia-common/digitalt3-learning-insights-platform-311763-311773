#!/bin/bash
set -euo pipefail

# MongoDB startup script following the same pattern
# NOTE: Kavia preview expects MongoDB to be reachable on port 5001.
DB_NAME="Cluster0"
DB_USER="rossiniheyyou_db_user"
DB_PASSWORD="eq6JEnQIAK8ODZZM"
DB_PORT="5001"

# MongoDB paths (explicit to ensure logs are discoverable)
MONGO_DBPATH="/var/lib/mongodb"
MONGO_LOGPATH="/var/lib/mongodb/mongod.log"
MONGO_PIDFILE="/var/run/mongodb/mongod.pid"
MONGO_SOCKET_PREFIX="/var/run/mongodb"

echo "Starting MongoDB setup..."

# Ensure data directory exists and is writable (common cause of silent startup failures)
echo "Ensuring MongoDB data dir exists and is writable: ${MONGO_DBPATH}"
sudo mkdir -p "${MONGO_DBPATH}"
# Try to set ownership to the typical mongodb user, but don't fail if user doesn't exist.
sudo chown -R mongodb:mongodb "${MONGO_DBPATH}" 2>/dev/null || true
# Ensure permissions allow writing in a wide range of runtime environments.
sudo chmod 775 "${MONGO_DBPATH}" 2>/dev/null || true

# Ensure runtime directory exists for unix socket/pidfile
sudo mkdir -p "${MONGO_SOCKET_PREFIX}"
sudo chmod 775 "${MONGO_SOCKET_PREFIX}" 2>/dev/null || true

# Ensure log file is present and writable (and has stable location)
# This is important for debuggability and also because mongod will fail to start if logpath cannot be opened.
echo "Ensuring MongoDB log file exists and is writable: ${MONGO_LOGPATH}"
sudo mkdir -p "$(dirname "${MONGO_LOGPATH}")"
sudo touch "${MONGO_LOGPATH}"
sudo chown mongodb:mongodb "${MONGO_LOGPATH}" 2>/dev/null || true
sudo chmod 664 "${MONGO_LOGPATH}" 2>/dev/null || true

# Helper: show recent log lines for diagnostics
tail_mongo_log() {
    echo ""
    echo "---- mongod log tail (${MONGO_LOGPATH}) ----"
    if [ -f "${MONGO_LOGPATH}" ]; then
        sudo tail -n 200 "${MONGO_LOGPATH}" || true
    else
        echo "Log file not found at ${MONGO_LOGPATH}"
    fi
    echo "---- end mongod log tail ----"
    echo ""
}

# Helper: verify something is actually LISTENING on the desired port (stronger readiness than just ping attempts).
is_port_listening() {
    local port="$1"

    # Prefer ss if available (common on modern Linux). Fall back to netstat.
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"
        return $?
    fi

    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"
        return $?
    fi

    # Last resort: use lsof if present.
    if command -v lsof >/dev/null 2>&1; then
        lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null | grep -q ":${port} "
        return $?
    fi

    # If we cannot check, return non-zero so caller can rely on mongosh check only.
    return 1
}

# If MongoDB is already responding on expected port, we consider it up.
# (We still verify port listening to avoid false-positives in some environments.)
if mongosh --port "${DB_PORT}" --eval "db.adminCommand('ping')" > /dev/null 2>&1; then
    echo "MongoDB responds to ping on port ${DB_PORT}."

    if is_port_listening "${DB_PORT}"; then
        echo "Verified: port ${DB_PORT} is listening."
    else
        echo "WARNING: Could not verify listening state for port ${DB_PORT} (ss/netstat/lsof unavailable or no listener found)."
    fi

    # Try to verify the database exists and user can connect
    if mongosh "mongodb://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}?authSource=admin" --eval "db.getName()" > /dev/null 2>&1; then
        echo "Database ${DB_NAME} is accessible with user ${DB_USER}."
    else
        echo "MongoDB is running but authentication might not be configured."
    fi

    echo ""
    echo "Database: ${DB_NAME}"
    echo "Admin user: ${DB_USER} (password: ${DB_PASSWORD})"
    echo "App user: appuser (password: ${DB_PASSWORD})"
    echo "Port: ${DB_PORT}"
    echo ""

    if [ -f "db_connection.txt" ]; then
        echo "To connect to the database, use:"
        echo "$(cat db_connection.txt)"
    else
        echo "To connect to the database, use:"
        echo "mongosh mongodb://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}?authSource=admin"
    fi

    echo ""
    echo "Script stopped - MongoDB server already running."
    exit 0
fi

# Check if MongoDB is running on a different port and stop it (to avoid port conflicts)
if pgrep -x mongod > /dev/null; then
    MONGO_PID="$(pgrep -x mongod | head -1)"
    CURRENT_PORT="$(sudo lsof -Pan -p "${MONGO_PID}" -i 2>/dev/null | grep -o ":[0-9]*" | grep -o "[0-9]*" | head -1 || true)"

    if [ "${CURRENT_PORT:-}" = "${DB_PORT}" ]; then
        echo "MongoDB is already running on port ${DB_PORT}!"
        echo "Script stopped - server already running."
        exit 0
    else
        echo "MongoDB is running on different port (${CURRENT_PORT:-unknown}), stopping it..."
        sudo pkill -x mongod || true
        sleep 2
    fi
fi

# Clean up any existing socket files
sudo rm -f /tmp/mongodb-*.sock 2>/dev/null || true

# Start MongoDB server using nohup.
# CRITICAL: Use explicit logpath and logappend so log always lands in /var/lib/mongodb/mongod.log.
echo "Starting MongoDB server..."
echo "Log file: ${MONGO_LOGPATH}"
nohup sudo mongod \
    --dbpath "${MONGO_DBPATH}" \
    --port "${DB_PORT}" \
    --bind_ip 0.0.0.0,127.0.0.1 \
    --logpath "${MONGO_LOGPATH}" \
    --logappend \
    --pidfilepath "${MONGO_PIDFILE}" \
    --unixSocketPrefix "${MONGO_SOCKET_PREFIX}" \
    > /dev/null 2>&1 &

# Wait for MongoDB to start (more retries for slow environments)
echo "Waiting for MongoDB to start..."
sleep 2

MAX_RETRIES=45
SLEEP_SECONDS=2

ready="0"
for i in $(seq 1 "${MAX_RETRIES}"); do
    # Check: process listening on port (strong signal that mongod bound successfully).
    if is_port_listening "${DB_PORT}"; then
        # Check: mongodb responds to ping (stronger end-to-end readiness).
        if mongosh --port "${DB_PORT}" --eval "db.adminCommand('ping')" > /dev/null 2>&1; then
            echo "MongoDB is ready and listening on port ${DB_PORT}!"
            ready="1"
            break
        fi
    fi

    echo "Waiting... (${i}/${MAX_RETRIES})"
    sleep "${SLEEP_SECONDS}"
done

if [ "${ready}" != "1" ]; then
    echo "ERROR: MongoDB failed to become ready and listening on port ${DB_PORT}."
    echo "Diagnostics:"
    echo "- mongod process: $(pgrep -x mongod >/dev/null 2>&1 && echo "present" || echo "not found")"
    echo "- port ${DB_PORT} listening: $(is_port_listening "${DB_PORT}" && echo "yes" || echo "no")"
    tail_mongo_log
    exit 1
fi

# Create database and user
echo "Setting up database and user..."
mongosh --port "${DB_PORT}" << EOF
// Switch to admin database for user creation
use admin

// Create admin user if it doesn't exist
if (db.getUser("${DB_USER}") == null) {
    db.createUser({
        user: "${DB_USER}",
        pwd: "${DB_PASSWORD}",
        roles: [
            { role: "userAdminAnyDatabase", db: "admin" },
            { role: "readWriteAnyDatabase", db: "admin" }
        ]
    });
}

// Switch to target database
use ${DB_NAME}

// Create application user for specific database
if (db.getUser("appuser") == null) {
    db.createUser({
        user: "appuser",
        pwd: "${DB_PASSWORD}",
        roles: [
            { role: "readWrite", db: "${DB_NAME}" }
        ]
    });
}

print("MongoDB setup complete!");
EOF

# Save connection command to a file
echo "mongosh mongodb://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}?authSource=admin" > db_connection.txt
echo "Connection string saved to db_connection.txt"

# Save environment variables to a file
cat > db_visualizer/mongodb.env << EOF
export MONGODB_URL="mongodb://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/?authSource=admin"
export MONGODB_DB="${DB_NAME}"
EOF

echo "MongoDB setup complete!"
echo "Database: ${DB_NAME}"
echo "Admin user: ${DB_USER} (password: ${DB_PASSWORD})"
echo "App user: appuser (password: ${DB_PASSWORD})"
echo "Port: ${DB_PORT}"
echo ""
echo "MongoDB log path: ${MONGO_LOGPATH}"
echo ""
echo "Environment variables saved to db_visualizer/mongodb.env"
echo "To use with Node.js viewer, run: source db_visualizer/mongodb.env"

echo "To connect to the database, use one of the following commands:"
echo "mongosh -u ${DB_USER} -p ${DB_PASSWORD} --port ${DB_PORT} --authenticationDatabase admin ${DB_NAME}"
echo "$(cat db_connection.txt)"

# MongoDB continues running in background
echo ""
echo "MongoDB is running in the background."

# --- Optional: start the db_visualizer (Node.js) ---
# Kavia preview/CI environments may invoke this container startup expecting the viewer to be available.
# We ensure dependencies are installed before starting to avoid "Cannot find module ..." errors.
#
# Controls:
#   START_DB_VISUALIZER=1  -> start viewer (default)
#   START_DB_VISUALIZER=0  -> skip viewer
#   DB_VISUALIZER_PORT=3000 -> port for viewer (default 3000)
START_DB_VISUALIZER="${START_DB_VISUALIZER:-1}"
DB_VISUALIZER_PORT="${DB_VISUALIZER_PORT:-3000}"

if [ "${START_DB_VISUALIZER}" = "1" ]; then
    echo ""
    echo "Starting db_visualizer..."

    pushd db_visualizer > /dev/null

    # Load DB connection env for the viewer if present
    if [ -f "mongodb.env" ]; then
        # shellcheck disable=SC1091
        source mongodb.env
    fi

    # Install dependencies (prefer npm ci when lockfile exists)
    if [ -f "package-lock.json" ]; then
        echo "Installing db_visualizer dependencies with npm ci..."
        npm ci --no-audit --no-fund
    else
        echo "Installing db_visualizer dependencies with npm install..."
        npm install --no-audit --no-fund
    fi

    # Start viewer in background
    echo "Launching db_visualizer on port ${DB_VISUALIZER_PORT}..."
    nohup env PORT="${DB_VISUALIZER_PORT}" npm start > db_visualizer.log 2>&1 &

    popd > /dev/null

    echo "db_visualizer started (logs: lms_database/db_visualizer/db_visualizer.log)"
fi

echo "You can now start your application."
