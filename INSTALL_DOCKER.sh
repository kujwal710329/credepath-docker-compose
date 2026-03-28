#!/bin/bash

# Docker Installation Script for Ubuntu/Debian

echo "========================================="
echo "  Docker Installation Script"
echo "========================================="
echo ""

# Check if Docker is already installed
if command -v docker &> /dev/null; then
    echo "✅ Docker is already installed!"
    docker --version
    echo ""
else
    echo "📦 Installing Docker..."
    echo ""

    # Update package index
    echo "Step 1: Updating package index..."
    sudo apt-get update

    # Install required packages
    echo "Step 2: Installing required packages..."
    sudo apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    # Add Docker's official GPG key
    echo "Step 3: Adding Docker GPG key..."
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    # Set up the repository
    echo "Step 4: Setting up Docker repository..."
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Update package index again
    echo "Step 5: Updating package index with Docker repository..."
    sudo apt-get update

    # Install Docker Engine
    echo "Step 6: Installing Docker Engine..."
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    echo ""
    echo "✅ Docker installed successfully!"
    docker --version
fi

# Check if user is in docker group
if groups $USER | grep &>/dev/null '\bdocker\b'; then
    echo "✅ User is already in docker group"
else
    echo ""
    echo "📝 Adding user to docker group..."
    sudo usermod -aG docker $USER
    echo "✅ User added to docker group"
    echo ""
    echo "⚠️  IMPORTANT: You need to log out and log back in for group changes to take effect!"
    echo "Or run: newgrp docker"
fi

echo ""
echo "========================================="
echo "  Verifying Docker Installation"
echo "========================================="

# Start Docker service
echo "Starting Docker service..."
sudo systemctl start docker
sudo systemctl enable docker

echo ""
echo "Testing Docker..."
docker run hello-world

echo ""
echo "========================================="
echo "  Docker Installation Complete!"
echo "========================================="
echo ""
echo "Docker version:"
docker --version
echo ""
echo "Docker Compose version:"
docker compose version
echo ""
echo "Next steps:"
echo "1. If you just added user to docker group, log out and log back in"
echo "2. Run: cd credepath-docker-compose"
echo "3. Run: ./start.sh"
echo ""
echo "========================================="
