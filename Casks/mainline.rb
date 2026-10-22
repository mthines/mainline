cask "mainline" do
  version "1.81.0"
  sha256 "e1a78b3e5d6b390388cba95a0d5be7af44acdbde3fb3dabf255ae2a1171a046a"

  url "https://github.com/mthines/mainline/releases/download/v#{version}/Mainline-v#{version}-macOS.zip"
  name "Mainline"
  desc "Lightweight macOS menu bar app for GitHub pull request notifications"
  homepage "https://github.com/mthines/mainline"

  depends_on macos: :ventura

  # Remove quarantine attribute so Gatekeeper does not block unsigned builds.
  # The app is quarantined by macOS on direct download; installing via brew
  # avoids Gatekeeper prompts because this preflight block clears the attribute.
  preflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", staged_path]
  end

  app "Mainline.app"

  # Quit Mainline before upgrading/uninstalling so the app releases its
  # Keychain/network handles cleanly.
  uninstall quit: "com.mainline.github-pr-notifier"

  zap trash: [
    "~/Library/Application Support/Mainline",
    "~/Library/Preferences/com.mainline.plist",
    "~/Library/Caches/Mainline",
    "~/Library/Saved Application State/Mainline.savedState",
  ]
end
