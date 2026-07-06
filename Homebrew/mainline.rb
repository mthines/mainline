cask "mainline" do
  version "1.0.0"
  # TODO: Update sha256 and url after creating a release artifact
  sha256 :no_check
  url "https://github.com/yourusername/mainline/releases/download/v#{version}/Mainline-#{version}.dmg"

  name "Mainline"
  desc "macOS menu bar app for GitHub pull request notifications"
  homepage "https://github.com/yourusername/mainline"

  app "Mainline.app"

  zap trash: [
    "~/Library/Application Support/com.mainline.github-pr-notifier",
    "~/Library/Preferences/com.mainline.github-pr-notifier.plist",
    "~/Library/Caches/com.mainline.github-pr-notifier",
  ]
end
