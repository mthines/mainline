cask "perch" do
  version "1.0.0"
  # TODO: Update sha256 and url after creating a release artifact
  sha256 :no_check
  url "https://github.com/yourusername/perch/releases/download/v#{version}/Perch-#{version}.dmg"

  name "Perch"
  desc "macOS menu bar app for GitHub pull request notifications"
  homepage "https://github.com/yourusername/perch"

  app "Perch.app"

  zap trash: [
    "~/Library/Application Support/com.perch.github-pr-notifier",
    "~/Library/Preferences/com.perch.github-pr-notifier.plist",
    "~/Library/Caches/com.perch.github-pr-notifier",
  ]
end
