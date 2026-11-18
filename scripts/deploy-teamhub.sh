
#!/bin/bash
set -Eeuo pipefail

# --------------------------------------------------
# Configuration
# --------------------------------------------------

AWS_REGION="ap-south-1"
AWS_ACCOUNT_ID="787257142877"
BUILD_NUMBER="${1:?Usage: ./deploy-teamhub.sh <build-number>}"

REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

FRONTEND_IMAGE="${REGISTRY}/teamhub-frontend:${BUILD_NUMBER}"
BACKEND_IMAGE="${REGISTRY}/teamhub-backend:${BUILD_NUMBER}"

FRONTEND_CONTAINER="teamhub-frontend"
BACKEND_CONTAINER="teamhub-backend"

ENV_FILE="/home/ssm-user/teamhub/backend.env"

# --------------------------------------------------
# Prerequisite checks
# --------------------------------------------------

echo "=========================================="
echo "Starting TeamHub deployment: ${BUILD_NUMBER}"
echo "=========================================="

command -v docker >/dev/null 2>&1 || {
    echo "ERROR: Docker is not installed."
    exit 1
}

command -v aws >/dev/null 2>&1 || {
    echo "ERROR: AWS CLI is not installed."
    exit 1
}

command -v curl >/dev/null 2>&1 || {
    echo "ERROR: curl is not installed."
    exit 1
}

test -f "$ENV_FILE" || {
    echo "ERROR: Backend environment file not found: $ENV_FILE"
    exit 1
}

# Ensure both existing containers are available for rollback.
docker inspect "$FRONTEND_CONTAINER" >/dev/null 2>&1 || {
    echo "ERROR: Existing frontend container not found."
    exit 1
}

docker inspect "$BACKEND_CONTAINER" >/dev/null 2>&1 || {
    echo "ERROR: Existing backend container not found."
    exit 1
}

# Capture the exact image IDs currently running.
OLD_FRONTEND=$(docker inspect -f '{{.Image}}' "$FRONTEND_CONTAINER")
OLD_BACKEND=$(docker inspect -f '{{.Image}}' "$BACKEND_CONTAINER")

echo "Previous frontend image: $OLD_FRONTEND"
echo "Previous backend image: $OLD_BACKEND"

# --------------------------------------------------
# Docker registry authentication
# --------------------------------------------------

echo "Authenticating with Amazon ECR..."

aws ecr get-login-password --region "$AWS_REGION" |
    docker login \
        --username AWS \
        --password-stdin "$REGISTRY"

# --------------------------------------------------
# Pull new images before stopping current containers
# --------------------------------------------------

echo "Pulling frontend image: $FRONTEND_IMAGE"
docker pull "$FRONTEND_IMAGE"

echo "Pulling backend image: $BACKEND_IMAGE"
docker pull "$BACKEND_IMAGE"

# --------------------------------------------------
# Health-check function
# --------------------------------------------------

check_health() {
    local url="$1"
    local attempt

    echo "Checking application health: $url"

    for attempt in $(seq 1 30); do
        if curl -fsS "$url" >/dev/null; then
            echo "Healthy: $url"
            return 0
        fi

        echo "Attempt $attempt/30 failed. Retrying..."
        sleep 5
    done

    echo "ERROR: Health check failed: $url"
    return 1
}

# --------------------------------------------------
# Rollback function
# --------------------------------------------------

rollback() {
    local exit_code=$?

    # Prevent the ERR trap from recursively invoking rollback.
    trap - ERR

    echo "=========================================="
    echo "DEPLOYMENT FAILED"
    echo "Restoring previous application version..."
    echo "=========================================="

    # Remove any partially deployed containers.
    docker rm -f "$FRONTEND_CONTAINER" "$BACKEND_CONTAINER" || true

    local frontend_rollback=true
    local backend_rollback=true

    # Restore previous frontend.
    docker run -d \
        --name "$FRONTEND_CONTAINER" \
        --restart unless-stopped \
        -p 80:80 \
        "$OLD_FRONTEND" || frontend_rollback=false

    # Restore previous backend.
    docker run -d \
        --name "$BACKEND_CONTAINER" \
        --restart unless-stopped \
        -p 8080:8080 \
        --env-file "$ENV_FILE" \
        "$OLD_BACKEND" || backend_rollback=false

    echo "Waiting for rollback health checks..."
    sleep 10

    # Verify restored frontend.
    if [ "$frontend_rollback" = true ]; then
        check_health "http://localhost/health" || frontend_rollback=false
    fi

    # Verify restored backend.
    if [ "$backend_rollback" = true ]; then
        check_health "http://localhost:8080/actuator/health" || backend_rollback=false
    fi

    echo "=========================================="

    if [ "$frontend_rollback" = true ] &&
       [ "$backend_rollback" = true ]; then
        echo "ROLLBACK SUCCESSFUL"
        echo "Previous application version is healthy."
    else
        echo "CRITICAL: ROLLBACK HEALTH VERIFICATION FAILED"
        echo "Inspect container status and logs immediately."

        docker ps -a || true
        docker logs "$FRONTEND_CONTAINER" --tail 50 || true
        docker logs "$BACKEND_CONTAINER" --tail 50 || true
    fi

    echo "=========================================="

    # Preserve the original deployment failure exit code.
    exit "$exit_code"
}

# --------------------------------------------------
# Activate rollback for deployment failures
# --------------------------------------------------

trap rollback ERR

# --------------------------------------------------
# Replace application containers
# --------------------------------------------------

echo "Stopping previous application containers..."

docker rm -f "$FRONTEND_CONTAINER" "$BACKEND_CONTAINER"

echo "Starting new frontend container..."

docker run -d \
    --name "$FRONTEND_CONTAINER" \
    --restart unless-stopped \
    -p 80:80 \
    "$FRONTEND_IMAGE"

echo "Starting new backend container..."

docker run -d \
    --name "$BACKEND_CONTAINER" \
    --restart unless-stopped \
    -p 8080:8080 \
    --env-file "$ENV_FILE" \
    "$BACKEND_IMAGE"

# --------------------------------------------------
# Verify new deployment
# --------------------------------------------------

echo "Waiting for application health checks..."

check_health "http://localhost/health"
check_health "http://localhost:8080/actuator/health"

# --------------------------------------------------
# Deployment successful
# --------------------------------------------------

trap - ERR

echo "=========================================="
echo "TEAMHUB DEPLOYMENT SUCCESSFUL"
echo "Build Number: ${BUILD_NUMBER}"
echo "Frontend: ${FRONTEND_IMAGE}"
echo "Backend: ${BACKEND_IMAGE}"
echo "=========================================="
