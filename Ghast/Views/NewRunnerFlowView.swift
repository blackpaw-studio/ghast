import SwiftUI

struct NewRunnerFlowView: View {
    let repositories: [GitHubRepository]
    
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRepository: GitHubRepository?
    @State private var showingAddRunner = false
    @State private var searchText = ""
    
    var filteredRepositories: [GitHubRepository] {
        if searchText.isEmpty {
            return repositories
        } else {
            return repositories.filter { repo in
                repo.name.localizedCaseInsensitiveContains(searchText) ||
                repo.fullName.localizedCaseInsensitiveContains(searchText) ||
                (repo.description?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Create New Runner")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("Select a repository to create a self-hosted runner for:")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                
                TextField("Search repositories...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .padding()
            
            // Repository list
            if filteredRepositories.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: searchText.isEmpty ? "folder" : "magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    
                    Text(searchText.isEmpty ? "No repositories available" : "No repositories found")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    
                    Text(searchText.isEmpty ? 
                         "Make sure you have access to repositories with GitHub Actions." :
                         "Try adjusting your search terms.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredRepositories) { repository in
                            NewRunnerRepositoryCard(
                                repository: repository,
                                isSelected: selectedRepository?.id == repository.id
                            ) {
                                selectedRepository = repository
                            }
                        }
                    }
                    .padding()
                }
            }
            
            Divider()
            
            // Navigation buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                
                Spacer()
                
                Button("Continue") {
                    if selectedRepository != nil {
                        showingAddRunner = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedRepository == nil)
            }
            .padding()
        }
        .frame(minWidth: 1000, idealWidth: 1200, maxWidth: 1400, minHeight: 700, idealHeight: 800, maxHeight: 1000)
        .sheet(isPresented: $showingAddRunner) {
            if let repository = selectedRepository {
                AddRunnerView(scope: repository.runnerScope, repository: repository) {
                    // Runner was added successfully
                    dismiss()
                }
            }
        }
    }
}

struct NewRunnerRepositoryCard: View {
    let repository: GitHubRepository
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                // Repository icon
                VStack {
                    Image(systemName: repository.isPrivate ? "lock.fill" : "globe")
                        .font(.title2)
                        .foregroundStyle(repository.isPrivate ? .orange : .green)
                }
                .frame(width: 40)
                
                // Repository info
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(repository.name)
                            .font(.headline)
                            .lineLimit(1)
                        
                        Spacer()
                        
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    
                    Text(repository.fullName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    
                    if let description = repository.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                
                Spacer(minLength: 0)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    NewRunnerFlowView(repositories: [
        GitHubRepository(
            id: 1,
            name: "Sample Repo",
            fullName: "user/sample-repo",
            description: "A sample repository for testing",
            isPrivate: false,
            owner: GitHubUser(id: 1, login: "user", avatarURL: "", name: "User", email: nil),
            htmlURL: "https://github.com/user/sample-repo"
        ),
        GitHubRepository(
            id: 2,
            name: "Private Project",
            fullName: "user/private-project",
            description: "A private repository for internal use",
            isPrivate: true,
            owner: GitHubUser(id: 1, login: "user", avatarURL: "", name: "User", email: nil),
            htmlURL: "https://github.com/user/private-project"
        )
    ])
}