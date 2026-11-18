
#!/bin/bash
set -Eeuo pipefail

AWS_REGION="ap-south-1"
AWS_ACCOUNT_ID="787257142877"
BUILD_NUMBER="${1:?Build number required}"

REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

FRONTEND_IMAGE="${REGISTRY}/teamhub-frontend:${BUILD_NUMBER}"
BACKEND_IMAGE="${REGISTRY}/teamhub-backend:${BUILD_NUMBER}"

FRONTEND_CONTAINER="teamhub-frontend"
BACKEND_CONTAINER="teamhub-backend"
ENV_FILE="/home/ssm-user/teamhub/backend.env"

echo "Deploying TeamHub build ${BUILD_NUMBER}"

# Verify prerequisites.
test -f "$ENV_FILE"

OLD_FRONTEND=$(docker inspect -f '{{.Image}}' "$FRONTEND_CONTAINER")
OLD_BACKEND=$(docker inspect -f '{{.Image}}' "$BACKEND_CONTAINER")

aws ecr get-login-password --region "$AWS_REGION" \
    | docker login \
        --username AWS \
        --password-stdin "$REGISTRY"

# Download both images before touching the running application.
docker pull "$FRONTEND_IMAGE"
docker pull "$BACKEND_IMAGE"

rollback() {
    local exit_code=$?
    trap - ERR

    echo "Deployment failed. Restoring previous version..."

    docker rm -f "$FRONTEND_CONTAINER" "$BACKEND_CONTAINER" || true

    docker run -d \
        --name "$FRONTEND_CONTAINER" \
        --restart unless-stopped \
        -p 80:80 \
        "$OLD_FRONTEND" || echo "Frontend rollback failed"

    docker run -d \
        --name "$BACKEND_CONTAINER" \
        --restart unless-stopped \
        -p 8080:8080 \
        --env-file "$ENV_FILE" \
        "$OLD_BACKEND" || echo "Backend rollback failed"

    echo "Rollback attempted. Check container health."
    exit "$exit_code"
}

# Activate rollback for failures during replacement or health checks.
trap rollback ERR

echo "Replacing application containers..."

docker rm -f "$FRONTEND_CONTAINER" "$BACKEND_CONTAINER"

docker run -d \
    --name "$FRONTEND_CONTAINER" \
    --restart unless-stopped \
    -p 80:80 \
    "$FRONTEND_IMAGE"

docker run -d \
    --name "$BACKEND_CONTAINER" \
    --restart unless-stopped \
    -p 8080:8080 \
    --env-file "$ENV_FILE" \
    "$BACKEND_IMAGE"

# Wait for applications to become healthy.
check_health() {
    local url="$1"

    for attempt in $(seq 1 30); do
        if curl -fsS "$url" >/dev/null; then
            echo "Healthy: $url"
            return 0
        fi
        sleep 5
    done

    echo "Health check failed: $url"
    return 1
}

check_health "http://localhost/health"
check_health "http://localhost:8080/actuator/health"

trap - ERR

echo "TeamHub build ${BUILD_NUMBER} deployed successfully."
