import SwiftUI

struct RateLimitView: View {
    @ObservedObject var rateLimitManager = RateLimitManager.shared
    
    var body: some View {
        if let info = rateLimitManager.rateLimitInfo {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(info.isNearLimit ? .orange : .secondary)
                    
                    Text("API Rate Limit")
                        .font(.headline)
                    
                    Spacer()
                    
                    if rateLimitManager.isRateLimited {
                        Text("EXCEEDED")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
                
                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 8)
                        
                        RoundedRectangle(cornerRadius: 4)
                            .fill(progressColor(for: info))
                            .frame(width: geometry.size.width * (info.percentageUsed / 100), height: 8)
                    }
                }
                .frame(height: 8)
                
                HStack {
                    Text("\(info.used) / \(info.limit) requests used")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    if let timeUntilReset = rateLimitManager.timeUntilReset() {
                        Text("Resets in \(rateLimitManager.formatTimeInterval(timeUntilReset))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if rateLimitManager.isRateLimited {
                    Text("You've exceeded the GitHub API rate limit. Please wait until the limit resets to continue using the app.")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.top, 4)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .shadow(radius: 2)
            .padding(.horizontal)
        }
    }
    
    private func progressColor(for info: RateLimitManager.RateLimitInfo) -> Color {
        if rateLimitManager.isRateLimited {
            return .red
        } else if info.percentageUsed > 90 {
            return .orange
        } else if info.percentageUsed > 75 {
            return .yellow
        } else {
            return .green
        }
    }
}

struct RateLimitBadge: View {
    @ObservedObject var rateLimitManager = RateLimitManager.shared
    
    var body: some View {
        if let info = rateLimitManager.rateLimitInfo, info.isNearLimit {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                
                Text("\(info.remaining)")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .foregroundColor(rateLimitManager.isRateLimited ? .red : .orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                (rateLimitManager.isRateLimited ? Color.red : Color.orange).opacity(0.2)
            )
            .cornerRadius(4)
        }
    }
}