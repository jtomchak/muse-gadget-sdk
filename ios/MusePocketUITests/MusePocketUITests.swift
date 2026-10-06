import XCTest

final class MusePocketUITests: XCTestCase {
  @MainActor func testPreviewTimerAndCardEditors() {
    let app = XCUIApplication()
    app.launchArguments = ["--preview"]
    app.launch()
    XCTAssertTrue(app.staticTexts["preview.banner"].waitForExistence(timeout: 8))
    app.tabBars.buttons["Tools"].tap()
    app.buttons["tools.add"].tap()
    let title = app.descendants(matching: .any)["preset.title"]
    XCTAssertTrue(title.waitForExistence(timeout: 3))
    title.tap()
    title.typeText("UI Tea")
    app.buttons["preset.save"].tap()
    XCTAssertTrue(app.staticTexts["UI Tea"].waitForExistence(timeout: 3))
    app.tabBars.buttons["Cards"].tap()
    app.buttons["cards.add"].tap()
    let cardTitle = app.descendants(matching: .any)["card.title"]
    cardTitle.tap()
    cardTitle.typeText("UI packing")
    let body = app.descendants(matching: .any)["card.body"]
    body.tap()
    body.typeText("Coffee and charger")
    app.buttons["card.send"].tap()
    XCTAssertTrue(app.staticTexts["UI packing"].waitForExistence(timeout: 3))
    app.tabBars.buttons["Assistant"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["assistant.prompt"].exists)
    app.tabBars.buttons["Settings"].tap()
    XCTAssertTrue(app.staticTexts["Clock & display care"].exists)
  }
}
