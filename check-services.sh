#!/bin/bash

echo "========================================="
echo "  Docker Services Diagnostic"
echo "========================================="
echo ""

# Check Docker containers status
echo "Container Status:"
echo "-----------------"
docker compose ps
echo ""

# Check frontend container logs
echo "========================================="
echo "Frontend Container Logs (last 50 lines):"
echo "========================================="
docker compose logs --tail=50 frontend
echo ""

# Check backend container logs
echo "========================================="
echo "Backend Container Logs (last 50 lines):"
echo "========================================="
docker compose logs --tail=50 backend
echo ""

# Check ML service container logs
echo "========================================="
echo "ML Service Container Logs (last 50 lines):"
echo "========================================="
docker compose logs --tail=50 jobs-recommender
echo ""

# Check if ports are listening
echo "========================================="
echo "Port Listening Status:"
echo "========================================="
echo "Checking port 3000 (Frontend):"
netstat -tuln | grep 3000 || echo "Port 3000 not listening"
echo ""
echo "Checking port 5000 (Backend):"
netstat -tuln | grep 5000 || echo "Port 5000 not listening"
echo ""
echo "Checking port 8000 (ML Service):"
netstat -tuln | grep 8000 || echo "Port 8000 not listening"
echo ""

# Try to curl the services
echo "========================================="
echo "Service Health Checks:"
echo "========================================="
echo "Frontend (http://localhost:3000):"
curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://localhost:3000 || echo "Failed to connect"
echo ""
echo "Backend (http://localhost:5000/health):"
curl -s http://localhost:5000/health || echo "Failed to connect"
echo ""
echo "ML Service (http://localhost:8000/api/health):"
curl -s http://localhost:8000/api/health || echo "Failed to connect"
echo ""
