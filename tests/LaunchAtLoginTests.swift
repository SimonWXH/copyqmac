// Launch at login: the system status mapping and the app-facing toggle
// behaviour, with a mock service so nothing is registered in this session.

import Foundation
import ServiceManagement

@MainActor
private final class MockLaunchAtLoginService: LaunchAtLoginService {
    var state: LaunchAtLoginState
    var failure: Error?
    /// State macOS would report after a successful enable. Defaults to enabled.
    var stateAfterEnable: LaunchAtLoginState = .enabled
    var stateAfterDisable: LaunchAtLoginState = .disabled
    private(set) var setCalls: [Bool] = []
    private(set) var openSettingsCount = 0

    init(state: LaunchAtLoginState) {
        self.state = state
    }

    func setEnabled(_ enabled: Bool) throws {
        setCalls.append(enabled)
        if let failure { throw failure }
        state = enabled ? stateAfterEnable : stateAfterDisable
    }

    func openSystemSettings() {
        openSettingsCount += 1
    }
}

private struct LaunchAtLoginTestError: LocalizedError {
    var errorDescription: String? { "Operation not permitted" }
}

func registerLaunchAtLoginTests() {
    TestRunner.add("SMAppService statuses map onto the toggle states") {
        MainActor.assumeIsolated {
            expectEqual(SystemLaunchAtLoginService.state(for: .enabled), .enabled)
            expectEqual(SystemLaunchAtLoginService.state(for: .notRegistered), .disabled)
            expectEqual(SystemLaunchAtLoginService.state(for: .requiresApproval), .requiresApproval)
            expectEqual(
                SystemLaunchAtLoginService.state(for: .notFound), .disabled,
                "a bundle macOS has no login item for yet is simply not registered, so a fresh install can enable it"
            )
            expect(
                !SystemLaunchAtLoginService.state(for: .notFound).isUnavailable,
                "the toggle must not be disabled on a fresh install"
            )
        }
    }

    TestRunner.add("a fresh bundle asks macOS to register when the toggle is enabled") {
        expectEqual(LaunchAtLoginAction.forStatus(.notFound, enabling: true), .register)
        expectEqual(LaunchAtLoginAction.forStatus(.notFound, enabling: false), .leaveAlone)
        expectEqual(LaunchAtLoginAction.forStatus(.notRegistered, enabling: true), .register)
        expectEqual(LaunchAtLoginAction.forStatus(.notRegistered, enabling: false), .leaveAlone)
        expectEqual(LaunchAtLoginAction.forStatus(.enabled, enabling: true), .leaveAlone)
        expectEqual(LaunchAtLoginAction.forStatus(.enabled, enabling: false), .unregister)
        expectEqual(LaunchAtLoginAction.forStatus(.requiresApproval, enabling: true), .leaveAlone)
        expectEqual(LaunchAtLoginAction.forStatus(.requiresApproval, enabling: false), .unregister)
    }

    TestRunner.add("the toggle reflects the real registration state") {
        MainActor.assumeIsolated {
            do {
                let mock = MockLaunchAtLoginService(state: .disabled)
                let model = AppModel(
                    history: ClipboardHistory(store: try ClipboardStore(inMemory: true)),
                    launchAtLogin: mock
                )
                model.bootstrap()
                model.refreshLaunchAtLoginState()
                expectEqual(model.launchAtLogin, .disabled, "the toggle must start from the system state")

                model.setLaunchAtLogin(true)
                expectEqual(mock.setCalls, [true], "the toggle must ask macOS to register the app")
                expectEqual(model.launchAtLogin, .enabled, "the toggle must show what macOS reports")
                expectNil(model.notice, "a successful toggle does not need a notice")
                expectNil(model.launchAtLoginProblem)

                model.setLaunchAtLogin(false)
                expectEqual(mock.setCalls, [true, false])
                expectEqual(model.launchAtLogin, .disabled)
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a registration failure is reported and leaves the real state visible") {
        MainActor.assumeIsolated {
            do {
                let mock = MockLaunchAtLoginService(state: .disabled)
                mock.failure = LaunchAtLoginTestError()
                let model = AppModel(
                    history: ClipboardHistory(store: try ClipboardStore(inMemory: true)),
                    launchAtLogin: mock
                )
                model.bootstrap()
                model.refreshLaunchAtLoginState()

                model.setLaunchAtLogin(true)

                expectEqual(model.launchAtLogin, .disabled, "the toggle must not pretend registration succeeded")
                expectNotNil(model.notice, "the failure must be surfaced")
                expect(
                    model.launchAtLoginProblem?.contains("Operation not permitted") == true,
                    "the reason must be shown next to the toggle, got \(String(describing: model.launchAtLoginProblem))"
                )
                expect(
                    model.notice?.contains("Operation not permitted") == true,
                    "the notice must include the system's reason, got \(String(describing: model.notice))"
                )
                expect(
                    model.notice?.contains("enable launch at login") == true,
                    "the notice must say what could not be done"
                )
                expect(!model.tabs.isEmpty, "the rest of the app must stay usable after the failure")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("pending approval is shown instead of a stale enabled toggle") {
        MainActor.assumeIsolated {
            do {
                let mock = MockLaunchAtLoginService(state: .disabled)
                mock.stateAfterEnable = .requiresApproval
                let model = AppModel(
                    history: ClipboardHistory(store: try ClipboardStore(inMemory: true)),
                    launchAtLogin: mock
                )
                model.bootstrap()
                model.refreshLaunchAtLoginState()

                model.setLaunchAtLogin(true)

                expectEqual(model.launchAtLogin, .requiresApproval)
                expect(!model.launchAtLogin.isEnabled, "a pending item is not a working login item yet")
                expect(
                    model.notice?.contains("Login Items") == true,
                    "the notice must point at where approval is granted"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the Login Items button opens System Settings") {
        MainActor.assumeIsolated {
            do {
                let mock = MockLaunchAtLoginService(state: .requiresApproval)
                let model = AppModel(
                    history: ClipboardHistory(store: try ClipboardStore(inMemory: true)),
                    launchAtLogin: mock
                )
                model.openLoginItemsSettings()
                expectEqual(mock.openSettingsCount, 1)
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a login-item launch stays in the menu bar and a manual launch opens the window") {
        let loginEvent = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        loginEvent.setParam(
            NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem),
            forKeyword: AEKeyword(keyAEPropData)
        )
        expect(
            AppLaunchSource.isLoginItemLaunch(appleEvent: loginEvent),
            "the login-item property must be recognised"
        )
        expectEqual(AppLaunchSource.resolve(isLoginItemLaunch: true), .loginItem)
        expect(
            !AppLaunchSource.resolve(isLoginItemLaunch: true).opensMainWindow,
            "a login-item launch must not open the main window"
        )

        let manualEvent = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        expect(
            !AppLaunchSource.isLoginItemLaunch(appleEvent: manualEvent),
            "an open-application event without the property is a manual launch"
        )
        expectEqual(AppLaunchSource.resolve(isLoginItemLaunch: false), .manual)
        expect(
            AppLaunchSource.resolve(isLoginItemLaunch: false).opensMainWindow,
            "a manual launch must keep showing the main window"
        )
        expect(!AppLaunchSource.isLoginItemLaunch(appleEvent: nil), "a missing event is a manual launch")
    }

    TestRunner.add("the approval notice disappears once the login item is approved") {
        MainActor.assumeIsolated {
            do {
                let mock = MockLaunchAtLoginService(state: .disabled)
                mock.stateAfterEnable = .requiresApproval
                let model = AppModel(
                    history: ClipboardHistory(store: try ClipboardStore(inMemory: true)),
                    launchAtLogin: mock
                )
                model.bootstrap()
                model.refreshLaunchAtLoginState()
                model.setLaunchAtLogin(true)
                expectEqual(model.notice, LaunchAtLoginNotice.requiresApproval)

                mock.state = .enabled
                model.refreshLaunchAtLoginState()
                expectEqual(model.launchAtLogin, .enabled)
                expectNil(model.notice, "approving the item must retire the approval notice")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("an unavailable notice is retracted when the item is usable") {
        MainActor.assumeIsolated {
            do {
                let mock = MockLaunchAtLoginService(state: .disabled)
                mock.stateAfterEnable = .unavailable("macOS could not find this app bundle.")
                let model = AppModel(
                    history: ClipboardHistory(store: try ClipboardStore(inMemory: true)),
                    launchAtLogin: mock
                )
                model.bootstrap()
                model.refreshLaunchAtLoginState()
                model.setLaunchAtLogin(true)
                expect(model.notice?.hasPrefix("Launch at login is unavailable: ") == true)

                mock.state = .disabled
                model.refreshLaunchAtLoginState()
                expectNil(model.notice, "an unregistered item no longer has an availability problem")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a successful toggle leaves an unrelated notice alone") {
        MainActor.assumeIsolated {
            do {
                let mock = MockLaunchAtLoginService(state: .disabled)
                let model = AppModel(
                    history: ClipboardHistory(store: try ClipboardStore(inMemory: true)),
                    launchAtLogin: mock
                )
                model.notice = AccessibilityNoticePolicy.pasteNeedsPermission

                model.setLaunchAtLogin(true)

                expectEqual(model.launchAtLogin, .enabled)
                expectEqual(
                    model.notice,
                    AccessibilityNoticePolicy.pasteNeedsPermission,
                    "enabling the login item must not clear the permission guidance"
                )

                mock.stateAfterEnable = .requiresApproval
                mock.state = .disabled
                model.setLaunchAtLogin(true)
                expectEqual(model.launchAtLogin, .requiresApproval)
                expectEqual(
                    model.notice,
                    AccessibilityNoticePolicy.pasteNeedsPermission,
                    "pending approval must not replace an unrelated notice"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a failure notice and its reason survive a refresh until the target state is reached") {
        MainActor.assumeIsolated {
            do {
                let enableMock = MockLaunchAtLoginService(state: .disabled)
                enableMock.failure = LaunchAtLoginTestError()
                let enableModel = AppModel(
                    history: ClipboardHistory(store: try ClipboardStore(inMemory: true)),
                    launchAtLogin: enableMock
                )
                enableModel.bootstrap()
                enableModel.refreshLaunchAtLoginState()
                enableModel.setLaunchAtLogin(true)
                expect(enableModel.notice?.hasPrefix("Could not enable launch at login") == true)

                enableModel.refreshLaunchAtLoginState()
                expect(
                    enableModel.notice?.hasPrefix("Could not enable launch at login") == true,
                    "a refresh that still sees the item disabled must keep the failure"
                )
                expectNotNil(enableModel.launchAtLoginProblem, "the reason must stay next to the toggle")

                enableMock.failure = nil
                enableMock.state = .enabled
                enableModel.refreshLaunchAtLoginState()
                expectNil(enableModel.notice, "reaching the requested state retires the failure")
                expectNil(enableModel.launchAtLoginProblem, "reaching the requested state clears the reason")

                let disableMock = MockLaunchAtLoginService(state: .enabled)
                disableMock.failure = LaunchAtLoginTestError()
                let disableModel = AppModel(
                    history: ClipboardHistory(store: try ClipboardStore(inMemory: true)),
                    launchAtLogin: disableMock
                )
                disableModel.bootstrap()
                disableModel.refreshLaunchAtLoginState()
                disableModel.setLaunchAtLogin(false)
                expect(disableModel.notice?.hasPrefix("Could not disable launch at login") == true)

                disableModel.refreshLaunchAtLoginState()
                expect(
                    disableModel.notice?.hasPrefix("Could not disable launch at login") == true,
                    "a refresh that still sees the item enabled must keep the failure"
                )
                expectNotNil(disableModel.launchAtLoginProblem)

                disableMock.failure = nil
                disableMock.state = .disabled
                disableModel.refreshLaunchAtLoginState()
                expectNil(disableModel.notice, "reaching the requested state retires the disable failure")
                expectNil(disableModel.launchAtLoginProblem)
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a failed disable is not retired by a state that only maps to off") {
        MainActor.assumeIsolated {
            do {
                let mappedStates: [LaunchAtLoginState] = [
                    .requiresApproval,
                    .unavailable("macOS could not find this app bundle."),
                ]
                for mappedState in mappedStates {
                    let mock = MockLaunchAtLoginService(state: .enabled)
                    mock.failure = LaunchAtLoginTestError()
                    let model = AppModel(
                        history: ClipboardHistory(store: try ClipboardStore(inMemory: true)),
                        launchAtLogin: mock
                    )
                    model.bootstrap()
                    model.refreshLaunchAtLoginState()
                    model.setLaunchAtLogin(false)
                    expect(model.notice?.hasPrefix("Could not disable launch at login") == true)

                    mock.state = mappedState
                    model.refreshLaunchAtLoginState()

                    expect(
                        model.notice?.hasPrefix("Could not disable launch at login") == true,
                        "\(mappedState) is not the requested disabled state and must keep the failure"
                    )
                    expectNotNil(
                        model.launchAtLoginProblem,
                        "\(mappedState) must keep the failure reason next to the toggle"
                    )

                    mock.state = .disabled
                    model.refreshLaunchAtLoginState()
                    expectNil(model.notice, "the exact requested state retires the failure")
                    expectNil(model.launchAtLoginProblem, "the exact requested state clears the reason")
                }
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a successful retry clears the previous failure notice") {
        MainActor.assumeIsolated {
            do {
                let mock = MockLaunchAtLoginService(state: .disabled)
                mock.failure = LaunchAtLoginTestError()
                let model = AppModel(
                    history: ClipboardHistory(store: try ClipboardStore(inMemory: true)),
                    launchAtLogin: mock
                )
                model.bootstrap()
                model.refreshLaunchAtLoginState()
                model.setLaunchAtLogin(true)
                expectNotNil(model.launchAtLoginProblem)

                mock.failure = nil
                model.setLaunchAtLogin(true)

                expectEqual(model.launchAtLogin, .enabled)
                expectNil(model.notice, "a successful toggle retires the old failure notice")
                expectNil(model.launchAtLoginProblem, "a successful toggle clears the old failure reason")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("dismissing the notice also clears the failure reason") {
        MainActor.assumeIsolated {
            do {
                let mock = MockLaunchAtLoginService(state: .disabled)
                mock.failure = LaunchAtLoginTestError()
                let model = AppModel(
                    history: ClipboardHistory(store: try ClipboardStore(inMemory: true)),
                    launchAtLogin: mock
                )
                model.bootstrap()
                model.refreshLaunchAtLoginState()
                model.setLaunchAtLogin(true)
                expectNotNil(model.launchAtLoginProblem)

                model.dismissNotice()

                expectNil(model.notice)
                expectNil(model.launchAtLoginProblem, "dismissing the notice must clear the matching reason")
                model.refreshLaunchAtLoginState()
                expectNil(model.notice)
                expectNil(model.launchAtLoginProblem)
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("refreshing the login-item state leaves unrelated notices alone") {
        MainActor.assumeIsolated {
            do {
                let mock = MockLaunchAtLoginService(state: .requiresApproval)
                let model = AppModel(
                    history: ClipboardHistory(store: try ClipboardStore(inMemory: true)),
                    launchAtLogin: mock
                )
                model.notice = "Import complete: 3 entries"
                model.refreshLaunchAtLoginState()
                expectEqual(model.notice, "Import complete: 3 entries")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }
}
