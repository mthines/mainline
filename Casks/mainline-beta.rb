cask "mainline-beta" do
  version "1.0.0-beta.1.1"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/mthines/mainline/releases/download/v#{version}/Mainline-v#{version}-macOS.zip"
  name "Mainline (beta)"
  desc "Lightweight macOS menu bar app for GitHub pull request notifications (beta)"
  homepage "https://github.com/mthines/mainline"

  depends_on macos: :ventura

  # Remove quarantine attribute so Gatekeeper does not block unsigned builds
  preflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{staged_path}/Mainline.app"]
  end

  # Beta and stable share /Applications/Mainline.app.
  # --force is required so Homebrew overwrites the app installed by the other cask.
  app "Mainline.app"

  uninstall quit: "com.mainline.github-pr-notifier"

  zap trash: [
    "~/Library/Application Support/com.mainline.github-pr-notifier",
    "~/Library/Preferences/com.mainline.github-pr-notifier.plist",
    "~/Library/Caches/com.mainline.github-pr-notifier",
    "~/Library/Saved Application State/com.mainline.github-pr-notifier.savedState",
  ]

  caveats <<~EOS
    This is a beta release. Install alongside or instead of the stable cask with:
      brew install --cask --force mthines/mainline/mainline-beta

    To roll back to stable:
      brew install --cask --force mthines/mainline/mainline
  EOS
end
