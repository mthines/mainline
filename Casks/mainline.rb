cask "mainline" do
  version "1.84.0"
  sha256 "5fa614891df3bf751b575c6d68bed74f31bc8a3302155822680fe6c3f1cd5e66"

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
