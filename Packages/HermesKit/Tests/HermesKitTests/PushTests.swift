import Foundation
import Testing

@testable import HermesKit

/// What the phone sends the talaria-push plugin, and how it learns its APNs environment.
struct PushTests {
  @Test func theRegistrationBodyIsWhatThePluginReads() {
    let registration = PushRegistration(
      deviceID: "6F1C-22", name: "Daniel's iPhone", token: PushRegistration.hex(Data([0xAB, 0x01, 0xFF])),
      pushToStartToken: nil, environment: "development", topic: "app.talaria.Talaria", teamID: "ABCDE12345",
      alerts: true, liveActivities: false, scope: .phone, bots: ["ada": "Ada"])
    let body = registration.body
    #expect(body["device_id"] == "6F1C-22")
    #expect(body["token"] == "ab01ff")
    // Unknown tokens are left out, not sent as null: the Mac keeps the one it has.
    #expect(body.object?["push_to_start_token"] == nil)
    #expect(body["environment"] == "development")
    #expect(body["topic"] == "app.talaria.Talaria")
    #expect(body["team_id"] == "ABCDE12345")
    #expect(body["alerts"] == true && body["live_activities"] == false)
    #expect(body["scope"] == "phone")
    #expect(body["bots"]["ada"] == "Ada")
  }

  @Test func signingFactsComeFromTheEmbeddedProfile() {
    let plist = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
        <key>TeamIdentifier</key><array><string>ABCDE12345</string></array>
        <key>Entitlements</key><dict><key>aps-environment</key><string>development</string></dict>
      </dict></plist>
      """
    // The plist sits inside binary CMS framing.
    var blob = Data([0x30, 0x82, 0x01, 0x00, 0x06, 0x09])
    blob.append(Data(plist.utf8))
    blob.append(Data([0x00, 0xA0, 0x82]))
    #expect(SigningFacts.from(provisioningProfile: blob, simulator: false) == SigningFacts(environment: "development", teamID: "ABCDE12345"))

    let production = blob.replacing(Data("development".utf8), with: Data("production".utf8))
    #expect(SigningFacts.from(provisioningProfile: production, simulator: false).environment == "production")
    // No profile: an App Store build on a device, or the simulator.
    #expect(SigningFacts.from(provisioningProfile: nil, simulator: false) == SigningFacts(environment: "production", teamID: nil))
    #expect(SigningFacts.from(provisioningProfile: nil, simulator: true).environment == "development")
    #expect(SigningFacts.from(provisioningProfile: Data("garbage".utf8), simulator: true).environment == "development")
  }
}
