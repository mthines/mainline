cask "mainline" do
  version "1.54.0"
  sha256 "fe6f174beba5526d93cd1779b51f762258f1ff646f3830f788a53f886e0f0dd6"

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
