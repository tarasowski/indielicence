# Homebrew formula for IndieLicense.
#
# To publish: create a tap repo (github.com/tarasowski/homebrew-tap), copy this
# file into its Formula/ directory, and fill in the placeholders from the
# .sha256 file the release workflow attaches to each GitHub release. Users
# then install with:
#
#   brew install tarasowski/tap/indielicense
#
class Indielicense < Formula
  desc "Offline license keys for indie Mac apps. No server, ever"
  homepage "https://github.com/tarasowski/indielicence"
  url "https://github.com/tarasowski/indielicence/releases/download/v1.0.0/indielicense-v1.0.0-macos-universal.tar.gz"
  sha256 "REPLACE_WITH_SHA256_FROM_RELEASE_ASSET"
  license "MIT"

  depends_on :macos

  def install
    bin.install "indielicense"
  end

  test do
    assert_match "indielicense", shell_output("#{bin}/indielicense --help")
    system bin/"indielicense", "init", "--product", "brewtest", "--key-dir", testpath
    assert_predicate testpath/"brewtest.private", :exist?
  end
end
