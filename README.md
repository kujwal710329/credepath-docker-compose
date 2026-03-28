# Credepath Docker Compose Orchestration

This repository orchestrates all Credepath services using Docker Compose for local development.

## Quick Start

### Prerequisites
- Docker Engine 24.0+ or Docker Desktop
- Docker Compose v2.20+
- Git

### Setup

1. **Clone all repositories** (if not already done):
```bash
# Create project directory
mkdir credepath-project && cd credepath-project

# Clone repositories
git clone <credepath-frontend-repo-url>
git clone <credepath-backend-repo-url>
git clone <jobs-recommender-repo-url>
git clone <credepath-docker-compose-repo-url>

# Your structure should be:
# credepath-project/
# ├── credepath-frontend/
# ├── credepath-backend/
# ├── jobs-recommender/
# └── credepath-docker-compose/
```

2. **Configure environment variables**:
```bash
cd credepath-docker-compose
cp .env.example .env
# Edit .env with your actual values
nano .env
```

3. **Start all services**:
```bash
docker-compose up -d
```

4. **View logs**:
```bash
docker-compose logs -f
```

5. **Access services**:
- Frontend: http://localhost:3000
- Backend API: http://localhost:5000
- ML Service: http://localhost:8000
- MongoDB: localhost:27017

## Common Commands

```bash
# Start all services
docker-compose up -d

# Stop all services
docker-compose down

# View logs
docker-compose logs -f

# View logs for specific service
docker-compose logs -f backend

# Rebuild and restart
docker-compose up -d --build

# Restart specific service
docker-compose restart backend

# Check service status
docker-compose ps

# Execute command in running container
docker-compose exec backend sh

# Stop and remove volumes (clean slate)
docker-compose down -v
```

## With Nginx Reverse Proxy

To run with Nginx:
```bash
docker-compose --profile with-nginx up -d
```

Access via:
- All services: http://localhost/
- Backend API: http://localhost/api/
- ML Service: http://localhost/ml/

## Troubleshooting

### Services won't start
```bash
# Check logs
docker-compose logs

# Check specific service
docker-compose logs backend
```

### Port already in use
```bash
# Change port in .env file
FRONTEND_PORT=3001
```

### MongoDB authentication issues
```bash
# Reset MongoDB (WARNING: deletes all data)
docker-compose down -v
docker-compose up -d mongodb
```

### Out of disk space
```bash
# Clean up Docker
docker system prune -a
```

## Development Workflow

The services are configured with volume mounts for hot-reloading:
- **Backend**: Uses nodemon for auto-restart
- **Frontend**: Uses Next.js dev mode with fast refresh
- **ML Service**: Uses uvicorn with reload

Make changes in your local code and they will be reflected immediately in the running containers.

## Architecture

```
┌─────────────┐
│   Nginx     │ (Optional)
│   :80       │
└──────┬──────┘
       │
   ┌───┴───┬──────────┐
   │       │          │
┌──▼───┐ ┌─▼──────┐ ┌▼─────────┐
│Front │ │Backend │ │ML Service│
│:3000 │ │:5000   │ │:8000     │
└──────┘ └────┬───┘ └──────────┘
              │
         ┌────▼─────┐
         │ MongoDB  │
         │  :27017  │
         └──────────┘
```

## For More Information

See [DOCKER_POLYREPO_DEPLOYMENT_GUIDE.md](../DOCKER_POLYREPO_DEPLOYMENT_GUIDE.md) for comprehensive documentation.
