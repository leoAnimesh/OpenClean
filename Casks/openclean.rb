# frozen_string_literal: true

# Homebrew cask for the signed, notarized OpenClean app. This repository is the tap:
#
#   brew install --cask leoanimesh/openclean/openclean
#
# `version` and `sha256` are bumped by scripts/bump-homebrew.sh, which the release workflow runs in a
# pull request after every release (see CONTRIBUTING.md "Homebrew").
cask "openclean" do
  version "0.5.0"
  sha256 "41f839f89a493b5bc448e89bfbcf2ada740ad0daab61b7b37e773deb6874ce6b"

  url "https://github.com/leoAnimesh/OpenClean/releases/download/v#{version}/OpenClean-#{version}.dmg"
  name "OpenClean"
  desc "Transparent, open-source disk cleaner"
  homepage "https://github.com/leoAnimesh/OpenClean"

  livecheck do
    url :url
    strategy :github_latest
  end

  # The app updates itself (Settings → Updates), so `brew upgrade` leaves it alone unless --greedy.
  auto_updates true
  depends_on macos: ">= :sonoma"

  app "OpenClean.app"

  # ~/Library/Application Support/OpenClean is deliberately not zapped: it holds the quarantine, i.e.
  # files you cleaned and can still restore. Remove it yourself once you no longer need them.
  zap trash: [
    "~/Library/Caches/com.openclean",
    "~/Library/HTTPStorages/com.openclean",
    "~/Library/Preferences/com.openclean.plist",
    "~/Library/Saved Application State/com.openclean.savedState",
  ]
end
