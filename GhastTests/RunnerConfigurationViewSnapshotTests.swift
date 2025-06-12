import XCTest
import SwiftUI
import SnapshotTesting
@testable import Ghast

@MainActor
final class RunnerConfigurationViewSnapshotTests: XCTestCase {
    
    override func setUp() async throws {
        try await super.setUp()
    }
    
    func testRunnerConfigurationViewEmpty() {
        let runner = LocalRunner(
            name: "Test Runner",
            repository: "user/test-repo",
            path: "/Users/user/actions-runner"
        )
        
        let view = RunnerConfigurationView(runner: runner)
        
        SnapshotTestHelpers.assertSnapshotNaturalSize(of: view, containerWidth: 900, containerHeight: 700)
    }
    
    func testRunnerConfigurationViewWithEnvironmentVariables() {
        var runner = LocalRunner(
            name: "Production Runner",
            repository: "company/production-app",
            path: "/Users/user/actions-runner"
        )
        runner.environmentVariables = [
            "NODE_ENV": "production",
            "API_URL": "https://api.example.com",
            "DEBUG": "false",
            "DATABASE_URL": "postgresql://localhost:5432/prod",
            "REDIS_URL": "redis://localhost:6379"
        ]
        
        let view = RunnerConfigurationView(runner: runner)
        
        SnapshotTestHelpers.assertSnapshotNaturalSize(of: view, containerWidth: 900, containerHeight: 700)
    }
    
    func testRunnerConfigurationViewWithScripts() {
        var runner = LocalRunner(
            name: "Docker Runner",
            repository: "team/docker-project",
            path: "/Users/user/actions-runner"
        )
        runner.preJobScript = """
        #!/bin/bash
        echo "Starting Docker services..."
        docker-compose up -d
        sleep 5
        docker ps
        """
        runner.postJobScript = """
        #!/bin/bash
        echo "Cleaning up Docker resources..."
        docker-compose down
        docker system prune -f
        docker volume prune -f
        """
        
        let view = RunnerConfigurationView(runner: runner)
        
        SnapshotTestHelpers.assertSnapshotNaturalSize(of: view, containerWidth: 900, containerHeight: 700)
    }
    
    func testRunnerConfigurationViewWithEverything() {
        var runner = LocalRunner(
            name: "Full Stack Runner",
            repository: "enterprise/full-stack-app",
            path: "/Users/user/actions-runner"
        )
        runner.environmentVariables = [
            "NODE_ENV": "staging",
            "API_BASE_URL": "https://staging-api.example.com",
            "AWS_REGION": "us-west-2",
            "CACHE_TTL": "3600"
        ]
        runner.preJobScript = """
        #!/bin/bash
        echo "Setting up test environment..."
        export PATH="/usr/local/bin:$PATH"
        npm ci
        npm run build:staging
        """
        runner.postJobScript = """
        #!/bin/bash
        echo "Cleaning up test artifacts..."
        rm -rf node_modules/.cache
        npm run clean
        """
        
        let view = RunnerConfigurationView(runner: runner)
        
        SnapshotTestHelpers.assertSnapshotNaturalSize(of: view, containerWidth: 900, containerHeight: 700)
    }
    
    func testRunnerConfigurationViewLargeWindow() {
        var runner = LocalRunner(
            name: "Large Window Test",
            repository: "user/large-project",
            path: "/Users/user/actions-runner"
        )
        runner.environmentVariables = [
            "TEST_VAR": "test_value"
        ]
        
        let view = RunnerConfigurationView(runner: runner)
        
        SnapshotTestHelpers.assertSnapshotNaturalSize(of: view, containerWidth: 1200, containerHeight: 900)
    }
    
    func testRunnerConfigurationViewSmallWindow() {
        let runner = LocalRunner(
            name: "Small Test",
            repository: "user/small",
            path: "/Users/user/runner"
        )
        
        let view = RunnerConfigurationView(runner: runner)
        
        SnapshotTestHelpers.assertSnapshotNaturalSize(of: view, containerWidth: 800, containerHeight: 600)
    }
    
    func testRunnerConfigurationViewLongRunnerName() {
        let runner = LocalRunner(
            name: "Very Long Runner Name That Should Handle Gracefully In The UI",
            repository: "organization/very-long-repository-name-that-might-overflow",
            path: "/Users/user/actions-runner-with-very-long-path"
        )
        
        let view = RunnerConfigurationView(runner: runner)
        
        SnapshotTestHelpers.assertSnapshotNaturalSize(of: view, containerWidth: 900, containerHeight: 700)
    }
    
    func testRunnerConfigurationViewManyEnvironmentVariables() {
        var runner = LocalRunner(
            name: "Many Vars Runner",
            repository: "user/env-heavy-project",
            path: "/Users/user/actions-runner"
        )
        runner.environmentVariables = [
            "API_KEY": "sk-1234567890abcdef",
            "DATABASE_URL": "postgresql://user:pass@localhost:5432/db",
            "REDIS_URL": "redis://localhost:6379/0",
            "AWS_ACCESS_KEY_ID": "AKIAIOSFODNN7EXAMPLE",
            "AWS_SECRET_ACCESS_KEY": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            "AWS_REGION": "us-west-2",
            "STRIPE_PUBLISHABLE_KEY": "pk_test_1234567890",
            "STRIPE_SECRET_KEY": "sk_test_0987654321",
            "SENTRY_DSN": "https://example@sentry.io/123456",
            "NEW_RELIC_LICENSE_KEY": "1234567890abcdef",
            "ELASTICSEARCH_URL": "http://localhost:9200",
            "RABBITMQ_URL": "amqp://localhost:5672"
        ]
        
        let view = RunnerConfigurationView(runner: runner)
        
        SnapshotTestHelpers.assertSnapshotNaturalSize(of: view, containerWidth: 900, containerHeight: 700)
    }
    
    func testRunnerConfigurationViewLongScripts() {
        var runner = LocalRunner(
            name: "Complex Scripts Runner",
            repository: "enterprise/complex-deployment",
            path: "/Users/user/actions-runner"
        )
        runner.preJobScript = """
        #!/bin/bash
        set -euo pipefail
        
        echo "Starting comprehensive pre-job setup..."
        
        # Update system packages
        sudo apt-get update -y
        sudo apt-get upgrade -y
        
        # Install required tools
        curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
        sudo apt-get install -y nodejs
        
        # Setup Docker
        sudo apt-get install -y docker.io docker-compose
        sudo systemctl start docker
        sudo usermod -aG docker $USER
        
        # Install AWS CLI
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip awscliv2.zip
        sudo ./aws/install
        
        # Setup environment
        export PATH="/usr/local/bin:$PATH"
        npm install -g yarn pnpm
        
        echo "Pre-job setup completed successfully!"
        """
        runner.postJobScript = """
        #!/bin/bash
        set -euo pipefail
        
        echo "Starting comprehensive cleanup..."
        
        # Stop all Docker containers
        docker stop $(docker ps -aq) || true
        docker rm $(docker ps -aq) || true
        
        # Clean Docker system
        docker system prune -af
        docker volume prune -f
        docker network prune -f
        
        # Clean npm/yarn caches
        npm cache clean --force
        yarn cache clean
        pnpm store prune
        
        # Clean temporary files
        rm -rf /tmp/*
        rm -rf ~/.cache/*
        
        # Clean logs
        sudo journalctl --vacuum-time=1d
        
        # Cleanup AWS credentials if temporary
        rm -f ~/.aws/credentials.tmp
        
        echo "Cleanup completed successfully!"
        """
        
        let view = RunnerConfigurationView(runner: runner)
        
        SnapshotTestHelpers.assertSnapshotNaturalSize(of: view, containerWidth: 900, containerHeight: 700)
    }
    
    func testRunnerConfigurationViewDarkMode() {
        let runner = LocalRunner(
            name: "Dark Mode Runner",
            repository: "user/dark-theme-project",
            path: "/Users/user/actions-runner"
        )
        
        let view = RunnerConfigurationView(runner: runner)
            .frame(width: 900, height: 700)
            .preferredColorScheme(.dark)
        
        SnapshotTestHelpers.assertSnapshotNaturalSize(of: view, containerWidth: 900, containerHeight: 700)
    }
}