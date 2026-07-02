import XCTest

final class CodexRateLimitDecodingTests: XCTestCase {
    func testAppServerListenSupportDetectsWebSocketSupport() {
        let legacyHelp = """
        --listen <URL>
            Supported values: `stdio://`, `unix://`, `unix://PATH`, `ws://IP:PORT`, `off`
        """
        let currentHelp = """
        --listen <URL>
            Supported values: `stdio://`, `unix://`, `unix://PATH`, `off`
        """

        XCTAssertTrue(CodexAppServerListenSupport.supportsWebSocket(helpText: legacyHelp))
        XCTAssertFalse(CodexAppServerListenSupport.supportsWebSocket(helpText: currentHelp))
    }

    func testDecodesPayloadAndPrefersMainCodexBucket() throws {
        let data = Data(
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "limitName": null,
                "primary": {
                  "usedPercent": 6,
                  "windowDurationMins": 300,
                  "resetsAt": 1775622013
                },
                "secondary": {
                  "usedPercent": 2,
                  "windowDurationMins": 10080,
                  "resetsAt": 1776208813
                },
                "planType": "pro"
              },
              "rateLimitsByLimitId": {
                "codex": {
                  "limitId": "codex",
                  "limitName": null,
                  "primary": {
                    "usedPercent": 6,
                    "windowDurationMins": 300,
                    "resetsAt": 1775622013
                  },
                  "secondary": {
                    "usedPercent": 2,
                    "windowDurationMins": 10080,
                    "resetsAt": 1776208813
                  },
                  "planType": "pro"
                },
                "codex_bengalfox": {
                  "limitId": "codex_bengalfox",
                  "limitName": "GPT-5.3-Codex-Spark",
                  "primary": {
                    "usedPercent": 0,
                    "windowDurationMins": 300,
                    "resetsAt": 1775624694
                  },
                  "secondary": {
                    "usedPercent": 0,
                    "windowDurationMins": 10080,
                    "resetsAt": 1776211494
                  },
                  "planType": "pro"
                }
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(AccountRateLimitsResponse.self, from: data)
        let snapshot = response.selectedSnapshot()

        XCTAssertEqual(snapshot.primary?.usedPercent, 6)
        XCTAssertEqual(snapshot.secondary?.usedPercent, 2)
        XCTAssertEqual(snapshot.secondary?.windowDurationMinutes, 10080)
    }

    func testBuildsUsageSnapshotWithAggregateAndModelBuckets() throws {
        let data = Data(
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "limitName": null,
                "primary": {
                  "usedPercent": 6,
                  "windowDurationMins": 300,
                  "resetsAt": 1775622013
                },
                "secondary": {
                  "usedPercent": 2,
                  "windowDurationMins": 10080,
                  "resetsAt": 1776208813
                },
                "planType": "pro"
              },
              "rateLimitsByLimitId": {
                "codex": {
                  "limitId": "codex",
                  "limitName": null,
                  "primary": {
                    "usedPercent": 6,
                    "windowDurationMins": 300,
                    "resetsAt": 1775622013
                  },
                  "secondary": {
                    "usedPercent": 2,
                    "windowDurationMins": 10080,
                    "resetsAt": 1776208813
                  },
                  "planType": "pro"
                },
                "codex_gpt55": {
                  "limitId": "codex_gpt55",
                  "limitName": "GPT-5.5",
                  "primary": {
                    "usedPercent": 9,
                    "windowDurationMins": 300,
                    "resetsAt": 1775624694
                  },
                  "secondary": {
                    "usedPercent": 4,
                    "windowDurationMins": 10080,
                    "resetsAt": 1776211494
                  },
                  "planType": "pro"
                },
                "codex_gpt54": {
                  "limitId": "codex_gpt54",
                  "limitName": "GPT-5.4",
                  "primary": {
                    "usedPercent": 3,
                    "windowDurationMins": 300,
                    "resetsAt": 1775624694
                  },
                  "secondary": {
                    "usedPercent": 1,
                    "windowDurationMins": 10080,
                    "resetsAt": 1776211494
                  },
                  "planType": "pro"
                }
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(AccountRateLimitsResponse.self, from: data)
        let usageSnapshot = response.usageSnapshot()

        XCTAssertEqual(usageSnapshot.displaySnapshot.primary?.usedPercent, 6)
        XCTAssertEqual(usageSnapshot.buckets.map(\.id), ["codex", "codex_gpt54", "codex_gpt55"])
        XCTAssertEqual(usageSnapshot.buckets.map(\.name), ["All models", "GPT-5.4", "GPT-5.5"])
        XCTAssertEqual(usageSnapshot.buckets.map(\.kind), [.aggregate, .model, .model])
        XCTAssertEqual(usageSnapshot.buckets.first { $0.id == "codex_gpt55" }?.snapshot.secondary?.usedPercent, 4)
    }

    func testDecodesWhamUsagePayloadIntoSnapshot() throws {
        let data = Data(
            """
            {
              "plan_type": "pro",
              "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                  "used_percent": 25,
                  "limit_window_seconds": 18000,
                  "reset_at": 1775622013
                },
                "secondary_window": {
                  "used_percent": 8,
                  "limit_window_seconds": 604800,
                  "reset_at": 1776208813
                }
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(WhamUsageResponse.self, from: data)
        let snapshot = try XCTUnwrap(response.selectedSnapshot())

        XCTAssertEqual(snapshot.primary?.usedPercent, 25)
        XCTAssertEqual(snapshot.primary?.windowDurationMinutes, 300)
        XCTAssertEqual(snapshot.secondary?.usedPercent, 8)
        XCTAssertEqual(snapshot.secondary?.windowDurationMinutes, 10080)
    }

    func testDecodesThreadTokenUsageNotification() throws {
        let data = Data(
            """
            {
              "threadId": "thread-123",
              "turnId": "turn-456",
              "tokenUsage": {
                "last": {
                  "inputTokens": 1200,
                  "cachedInputTokens": 900,
                  "outputTokens": 300,
                  "reasoningOutputTokens": 40,
                  "totalTokens": 1500
                },
                "total": {
                  "inputTokens": 10000,
                  "cachedInputTokens": 7000,
                  "outputTokens": 2000,
                  "reasoningOutputTokens": 400,
                  "totalTokens": 12000
                },
                "modelContextWindow": 258400
              }
            }
            """.utf8
        )

        let payload = try JSONDecoder().decode(ThreadTokenUsageUpdatedNotificationPayload.self, from: data)
        let notification = payload.toDomainNotification()

        XCTAssertEqual(notification.threadID, "thread-123")
        XCTAssertEqual(notification.turnID, "turn-456")
        XCTAssertNil(notification.model)
        XCTAssertEqual(notification.tokenUsage.modelContextWindow, 258400)
        XCTAssertEqual(notification.tokenUsage.last.cachedInputTokens, 900)
        XCTAssertEqual(notification.tokenUsage.last.reasoningOutputTokens, 40)
        XCTAssertEqual(notification.tokenUsage.total.inputTokens, 10000)
        XCTAssertEqual(notification.tokenUsage.total.totalTokens, 12000)
    }

    func testDecodesThreadTokenUsageNotificationSafeDimensions() throws {
        let data = Data(
            """
            {
              "thread_id": "thread-123",
              "turn_id": "turn-456",
              "originator": "vscode",
              "source": {
                "subagent": {
                  "thread_spawn": {
                    "parent_thread_id": "019c-parent-thread",
                    "depth": 2,
                    "agent_role": "explorer",
                    "agent_nickname": "Raman"
                  }
                }
              },
              "thread_source": "cli",
              "cli_version": "0.78.0",
              "model_provider": "openai",
              "memory_mode": "enabled",
              "approval_policy": "never",
              "sandbox_policy": {"type": "danger-full-access"},
              "permission_profile": {"type": "full"},
              "realtime_active": true,
              "truncation_policy": {"mode": "auto", "limit": 10000},
              "usage_mode": "/fast",
              "token_usage": {
                "last": {
                  "inputTokens": 1200,
                  "cachedInputTokens": 900,
                  "outputTokens": 300,
                  "reasoningOutputTokens": 40,
                  "totalTokens": 1500
                },
                "total": {
                  "inputTokens": 10000,
                  "cachedInputTokens": 7000,
                  "outputTokens": 2000,
                  "reasoningOutputTokens": 400,
                  "totalTokens": 12000
                },
                "model_context_window": 258400
              }
            }
            """.utf8
        )

        let payload = try JSONDecoder().decode(ThreadTokenUsageUpdatedNotificationPayload.self, from: data)
        let notification = payload.toDomainNotification()
        let dimensionPairs = notification.dimensions.map { "\($0.key.rawValue)=\($0.value)" }

        XCTAssertEqual(notification.threadID, "thread-123")
        XCTAssertEqual(notification.turnID, "turn-456")
        XCTAssertEqual(notification.tokenUsage.modelContextWindow, 258400)
        XCTAssertEqual(
            dimensionPairs,
            [
                "agent_nickname=Raman",
                "agent_role=explorer",
                "approval_policy=never",
                "cli_version=0.78.0",
                "is_subagent=true",
                "memory_mode=enabled",
                "model_provider=openai",
                "originator=vscode",
                "permission_profile=full",
                "realtime_active=true",
                "sandbox_type=danger-full-access",
                "source_kind=subagent",
                "subagent_depth=2",
                "subagent_parent_thread_id=019c-parent-thread",
                "thread_source=cli",
                "truncation_policy=auto",
                "usage_mode=fast",
            ]
        )
    }

    func testDecodesThreadTokenUsageNotificationModelIdentifiers() throws {
        XCTAssertEqual(
            try decodeTokenUsageModel(extraRoot: #","model":" codex-future-1 ""#),
            "codex-future-1"
        )
        XCTAssertEqual(
            try decodeTokenUsageModel(extraRoot: #","slug":"gpt-5.4""#),
            "gpt-5.4"
        )
        XCTAssertEqual(
            try decodeTokenUsageModel(extraTokenUsage: #","modelSlug":"o-series-next""#),
            "o-series-next"
        )
        XCTAssertEqual(
            try decodeTokenUsageModel(extraTokenUsage: #","info":{"slug":"model-from-info"}"#),
            "model-from-info"
        )
        XCTAssertNil(try decodeTokenUsageModel())
    }

    func testNormalizesThreadTokenUsageNotificationModelIdentifiers() throws {
        XCTAssertEqual(
            try decodeTokenUsageModel(extraRoot: #","model":"gpt-5.5\nTests/CodexUsageMenuBarTests/UsageHistoryStoreTests.swift:611:""#),
            "gpt-5.5"
        )
        XCTAssertEqual(
            try decodeTokenUsageModel(extraRoot: #","model":"o-series-next""#),
            "o-series-next"
        )
        XCTAssertEqual(
            try decodeTokenUsageModel(extraRoot: #","model":"gpt-5.4-mini""#),
            "gpt-5.4-mini"
        )
        XCTAssertNil(
            try decodeTokenUsageModel(extraRoot: #","model":"/Users/example/.codex/sessions/session.jsonl""#)
        )
        XCTAssertNil(
            try decodeTokenUsageModel(extraRoot: #","model":"event.name=codex.sse_event""#)
        )
    }

    func testTokenPayloadAuditorCapturesOnlySafeMetadata() throws {
        let params = try jsonObject(
            """
            {
              "thread_id": "thread-123",
              "turn_id": "turn-456",
              "modelSlug": "gpt-5.5",
              "source": {
                "subagent": {
                  "thread_spawn": {
                    "parent_thread_id": "parent-1",
                    "depth": 2,
                    "agent_role": "worker",
                    "agent_nickname": "Build"
                  }
                }
              },
              "approval_policy": {"type": "never"},
              "sandbox_policy": {"type": "danger-full-access"},
              "prompt": "do not store this text",
              "auth_token": "secret-token",
              "tool_payload": {"command": "rm -rf /"},
              "token_usage": {
                "last": {
                  "inputTokens": 120,
                  "cachedInputTokens": 90,
                  "outputTokens": 30,
                  "reasoningOutputTokens": 4,
                  "totalTokens": 150
                },
                "total": {
                  "inputTokens": 1000,
                  "cachedInputTokens": 700,
                  "outputTokens": 200,
                  "reasoningOutputTokens": 40,
                  "totalTokens": 1200
                },
                "info": {
                  "cwd": "/Users/example/Project",
                  "reasoning_effort": "xhigh",
                  "usage_mode": "/fast",
                  "cli_version": "0.78.0"
                }
              }
            }
            """
        )

        let audit = try XCTUnwrap(CodexTokenPayloadAuditor.audit(params: params, capturedAt: Date(timeIntervalSince1970: 1_777_000_000)))

        XCTAssertEqual(audit.threadID, "thread-123")
        XCTAssertEqual(audit.turnID, "turn-456")
        XCTAssertEqual(try auditField("modelSlug", in: audit).normalizedValue, "gpt-5.5")
        XCTAssertEqual(try auditField("tokenUsage.info.cwd", in: audit).normalizedValue, "/Users/example/Project")
        XCTAssertEqual(try auditField("tokenUsage.info.reasoningEffort", in: audit).normalizedValue, "xhigh")
        XCTAssertEqual(try auditField("source", in: audit).dimensionValue, "subagent")
        XCTAssertEqual(try auditField("approvalPolicy", in: audit).dimensionValue, "never")
        XCTAssertEqual(try auditField("sandboxPolicy", in: audit).dimensionValue, "danger-full-access")
        XCTAssertEqual(try auditField("tokenUsage.info.usageMode", in: audit).dimensionValue, "fast")
        XCTAssertEqual(try auditField("tokenUsage.info.cliVersion", in: audit).dimensionValue, "0.78.0")
        XCTAssertTrue(audit.hasModelMetadata)
        XCTAssertTrue(audit.hasProjectMetadata)
        XCTAssertTrue(audit.hasEffortMetadata)
        XCTAssertTrue(audit.hasSourceMetadata)
        XCTAssertTrue(audit.hasRuntimePolicyMetadata)
        XCTAssertFalse(audit.fields.contains { $0.keyPath.contains("prompt") || $0.keyPath.contains("auth") || $0.keyPath.contains("tool") })
        XCTAssertFalse(audit.fields.compactMap(\.sanitizedValue).contains { $0.contains("do not store") || $0.contains("secret-token") || $0.contains("rm -rf") })
    }

    @MainActor
    func testAppServerClientEmitsAuditAndTokenUsageIndependently() throws {
        let client = CodexAppServerClient()
        var receivedAudit: CodexTokenUsagePayloadAudit?
        var receivedNotification: CodexTokenUsageNotification?
        var diagnosticEvents: [CodexAppServerAuditDiagnosticEvent] = []
        client.onTokenUsagePayloadAudit = { receivedAudit = $0 }
        client.onTokenUsage = { receivedNotification = $0 }
        client.onAppServerAuditDiagnosticEvent = { diagnosticEvents.append($0) }

        try client.handleIncomingMessage(data: Data(
            """
            {
              "method": "thread/tokenUsage/updated",
              "params": {
                "threadId": "thread-1",
                "turnId": "turn-1",
                "model": "gpt-5.5",
                "source": {"unsupported": {"message": "ignored"}},
                "tokenUsage": {
                  "last": {
                    "inputTokens": 120,
                    "cachedInputTokens": 90,
                    "outputTokens": 30,
                    "reasoningOutputTokens": 4,
                    "totalTokens": 150
                  },
                  "total": {
                    "inputTokens": 1000,
                    "cachedInputTokens": 700,
                    "outputTokens": 200,
                    "reasoningOutputTokens": 40,
                    "totalTokens": 1200
                  }
                }
              }
            }
            """.utf8
        ))

        let audit = try XCTUnwrap(receivedAudit)
        let notification = try XCTUnwrap(receivedNotification)

        XCTAssertEqual(notification.threadID, "thread-1")
        XCTAssertEqual(notification.model, "gpt-5.5")
        XCTAssertEqual(notification.tokenUsage.total.totalTokens, 1200)
        XCTAssertEqual(try auditField("model", in: audit).normalizedValue, "gpt-5.5")
        XCTAssertEqual(try auditField("source", in: audit).presence, .unsupported)
        XCTAssertTrue(diagnosticEvents.contains(.inboundMethod("thread/tokenUsage/updated")))
        XCTAssertTrue(diagnosticEvents.contains(.tokenUsageNotification))
        XCTAssertTrue(diagnosticEvents.contains(.auditSanitizeAttempt(success: true)))
    }

    @MainActor
    func testAppServerClientEmitsAuditBeforeMalformedTokenPayloadThrows() throws {
        let client = CodexAppServerClient()
        var receivedAudit: CodexTokenUsagePayloadAudit?
        var receivedNotification: CodexTokenUsageNotification?
        var diagnosticEvents: [CodexAppServerAuditDiagnosticEvent] = []
        client.onTokenUsagePayloadAudit = { receivedAudit = $0 }
        client.onTokenUsage = { receivedNotification = $0 }
        client.onAppServerAuditDiagnosticEvent = { diagnosticEvents.append($0) }

        XCTAssertThrowsError(try client.handleIncomingMessage(data: Data(
            """
            {
              "method": "thread/tokenUsage/updated",
              "params": {
                "threadId": "thread-1",
                "turnId": "turn-1",
                "model": "gpt-5.5"
              }
            }
            """.utf8
        )))

        XCTAssertEqual(receivedAudit?.threadID, "thread-1")
        XCTAssertEqual(try auditField("model", in: XCTUnwrap(receivedAudit)).normalizedValue, "gpt-5.5")
        XCTAssertNil(receivedNotification)
        XCTAssertTrue(diagnosticEvents.contains(.tokenUsageNotification))
        XCTAssertTrue(diagnosticEvents.contains(.auditSanitizeAttempt(success: true)))
        XCTAssertTrue(diagnosticEvents.contains { event in
            if case .receiveError = event {
                return true
            }
            return false
        })
    }

    @MainActor
    func testAppServerClientEmitsDiagnosticsForGenericAndRateLimitNotifications() throws {
        let client = CodexAppServerClient()
        var diagnosticEvents: [CodexAppServerAuditDiagnosticEvent] = []
        client.onAppServerAuditDiagnosticEvent = { diagnosticEvents.append($0) }

        try client.handleIncomingMessage(data: Data(
            """
            {
              "method": "example/notification",
              "params": {}
            }
            """.utf8
        ))

        XCTAssertTrue(diagnosticEvents.contains(.inboundMethod("example/notification")))

        XCTAssertThrowsError(try client.handleIncomingMessage(data: Data(
            """
            {
              "method": "account/rateLimits/updated",
              "params": {}
            }
            """.utf8
        )))

        XCTAssertTrue(diagnosticEvents.contains(.inboundMethod("account/rateLimits/updated")))
        XCTAssertTrue(diagnosticEvents.contains(.rateLimitNotification))
        XCTAssertTrue(diagnosticEvents.contains { event in
            if case .receiveError = event {
                return true
            }
            return false
        })
    }

    @MainActor
    func testAppServerClientEmitsSanitizedRemoteControlDiagnostics() throws {
        let client = CodexAppServerClient()
        var diagnosticEvents: [CodexAppServerAuditDiagnosticEvent] = []
        client.onAppServerAuditDiagnosticEvent = { diagnosticEvents.append($0) }

        try client.handleIncomingMessage(data: Data(
            """
            {
              "method": "remoteControl/status/changed",
              "params": {
                "status": "connected",
                "websocket_url": "wss://secret.example/ws",
                "account_id": "acct-secret",
                "server_id": "server-secret",
                "environment_id": "environment-secret",
                "message": "do not store this",
                "auth": "secret-token"
              }
            }
            """.utf8
        ))

        XCTAssertTrue(diagnosticEvents.contains(.inboundMethod("remoteControl/status/changed")))
        XCTAssertTrue(diagnosticEvents.contains(.remoteControlNotification(status: .connected, warningText: nil)))
        XCTAssertFalse(diagnosticEvents.contains { event in
            if case .receiveError(let text) = event {
                return text.contains("secret") || text.contains("wss://")
            }
            if case .remoteControlNotification(_, let warningText) = event {
                return warningText?.contains("secret") == true || warningText?.contains("wss://") == true
            }
            return false
        })
    }

    func testNotificationAuditSanitizerCapturesSupportedSafeFieldsOnly() throws {
        let settingsRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "thread/settings/updated",
            params: [
                "threadId": "thread-secret",
                "threadSettings": [
                    "cwd": "/Users/private/project",
                    "approvalPolicy": ["granular": ["rules": true, "skill_approval": true]],
                    "approvalsReviewer": "guardian_subagent",
                    "sandboxPolicy": [
                        "type": "workspaceWrite",
                        "writableRoots": ["/Users/private/project"],
                        "networkAccess": true,
                    ],
                    "activePermissionProfile": ["id": ":workspace", "extends": "default"],
                    "model": "gpt-5.5 extra text is ignored",
                    "modelProvider": "openai",
                    "serviceTier": "priority",
                    "effort": "xhigh",
                    "summary": "detailed",
                    "collaborationMode": ["mode": "plan", "settings": ["reasoning_effort": "xhigh"]],
                    "personality": "pragmatic",
                ],
            ] as [String: Any]
        ))

        XCTAssertTrue(settingsRecord.isSupported)
        XCTAssertEqual(settingsRecord.safeValues["model"], "gpt-5.5")
        XCTAssertEqual(settingsRecord.safeValues["modelProvider"], "openai")
        XCTAssertEqual(settingsRecord.safeValues["effort"], "xhigh")
        XCTAssertEqual(settingsRecord.safeValues["approvalPolicy"], "granular")
        XCTAssertEqual(settingsRecord.safeValues["approvalsReviewer"], "guardian_subagent")
        XCTAssertEqual(settingsRecord.safeValues["sandboxPolicy"], "workspaceWrite")
        XCTAssertEqual(settingsRecord.safeValues["collaborationMode"], "plan")
        XCTAssertEqual(settingsRecord.safeValues["hasCwd"], "true")
        XCTAssertEqual(settingsRecord.safeValues["hasServiceTier"], "true")
        XCTAssertEqual(settingsRecord.safeValues["hasPermissionProfile"], "true")
        XCTAssertNil(settingsRecord.safeValues["cwd"])
        XCTAssertNil(settingsRecord.safeValues["serviceTier"])
        XCTAssertGreaterThan(settingsRecord.rejectedUnsafeFieldCount, 0)

        let rerouteRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "model/rerouted",
            params: [
                "threadId": "thread-secret",
                "turnId": "turn-secret",
                "fromModel": "gpt-5.4",
                "toModel": "gpt-5.5",
                "reason": "highRiskCyberActivity",
            ] as [String: Any]
        ))

        XCTAssertEqual(rerouteRecord.safeValues["fromModel"], "gpt-5.4")
        XCTAssertEqual(rerouteRecord.safeValues["toModel"], "gpt-5.5")
        XCTAssertEqual(rerouteRecord.safeValues["reason"], "highRiskCyberActivity")
        XCTAssertEqual(rerouteRecord.presenceFlags, ["threadId", "turnId"])

        let turnRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "turn/completed",
            params: [
                "threadId": "thread-secret",
                "turn": [
                    "id": "turn-secret",
                    "status": "completed",
                    "items": [["message": "do not store"]],
                    "startedAt": 1_777_100_000,
                    "completedAt": 1_777_100_010,
                    "durationMs": 10_000,
                    "error": NSNull(),
                ],
            ] as [String: Any]
        ))

        XCTAssertEqual(turnRecord.safeValues["turnStatus"], "completed")
        XCTAssertEqual(turnRecord.safeValues["itemCount"], "1")
        XCTAssertEqual(turnRecord.safeValues["hasStartedAt"], "true")
        XCTAssertEqual(turnRecord.safeValues["hasCompletedAt"], "true")
        XCTAssertEqual(turnRecord.safeValues["hasDuration"], "true")
        XCTAssertNil(turnRecord.safeValues["items"])
    }

    func testNotificationAuditSanitizerRejectsContentAndUnknownValues() throws {
        let warningRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "warning",
            params: [
                "threadId": "thread-secret",
                "message": "do not store this warning",
                "account_id": "acct-secret",
                "websocket_url": "wss://secret.example/ws",
                "auth": "secret-token",
                "tool": ["payload": "rm -rf"],
            ] as [String: Any]
        ))

        XCTAssertTrue(warningRecord.isSupported)
        XCTAssertEqual(warningRecord.safeValues["hasMessage"], "true")
        XCTAssertEqual(warningRecord.presenceFlags, ["threadId"])
        XCTAssertGreaterThanOrEqual(warningRecord.rejectedUnsafeFieldCount, 5)

        let unknownRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "future/notification",
            params: [
                "message": "do not store",
                "account_id": "acct-secret",
            ] as [String: Any]
        ))

        XCTAssertFalse(unknownRecord.isSupported)
        XCTAssertEqual(unknownRecord.unsupportedShapeCount, 1)

        let encoded = try JSONEncoder().encode(warningRecord)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains("do not store"))
        XCTAssertFalse(json.contains("acct-secret"))
        XCTAssertFalse(json.contains("wss://"))
        XCTAssertFalse(json.contains("secret-token"))
        XCTAssertFalse(json.contains("rm -rf"))
        XCTAssertFalse(json.contains("thread-secret"))
    }

    func testGeneratedNotificationSurfaceFixtureContainsMethodNamesOnly() throws {
        let methods = try CodexAppServerNotificationSurfaceMethodFixture.parseMethodNames(
            Self.acceptedGeneratedServerNotificationMethodsFixture
        )
        let nonEmptyLines = Self.acceptedGeneratedServerNotificationMethodsFixture
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        XCTAssertEqual(methods.count, 66)
        XCTAssertEqual(methods, nonEmptyLines)
        XCTAssertEqual(Set(methods).count, methods.count)

        for method in methods {
            XCTAssertTrue(CodexAppServerNotificationSurfaceMethodFixture.isMethodNameOnly(method), method)
            XCTAssertFalse(method.contains("://"), method)
            XCTAssertFalse(method.contains("{"), method)
            XCTAssertFalse(method.contains("}"), method)
            XCTAssertFalse(method.contains("\""), method)
            XCTAssertFalse(method.contains(" "), method)
        }

        XCTAssertThrowsError(try CodexAppServerNotificationSurfaceMethodFixture.parseMethodNames(
            #"{"method":"thread/started","params":{"thread":{"id":"private"}}}"#
        )) { error in
            XCTAssertEqual(
                error as? CodexAppServerNotificationSurfaceMethodFixture.ParseError,
                .invalidLine(lineNumber: 1)
            )
            XCTAssertFalse(String(describing: error).contains("private"))
            XCTAssertFalse(String(describing: error).contains("thread/started"))
        }

        XCTAssertThrowsError(try CodexAppServerNotificationSurfaceMethodFixture.parseMethodNames(
            "/Users/private/project"
        )) { error in
            XCTAssertEqual(
                error as? CodexAppServerNotificationSurfaceMethodFixture.ParseError,
                .invalidLine(lineNumber: 1)
            )
            XCTAssertFalse(String(describing: error).contains("/Users/private"))
        }

        XCTAssertThrowsError(try CodexAppServerNotificationSurfaceMethodFixture.parseMethodNames(
            "../private"
        )) { error in
            XCTAssertEqual(
                error as? CodexAppServerNotificationSurfaceMethodFixture.ParseError,
                .invalidLine(lineNumber: 1)
            )
            XCTAssertFalse(String(describing: error).contains("../private"))
        }

        XCTAssertThrowsError(try CodexAppServerNotificationSurfaceMethodFixture.parseMethodNames(
            "example.com/account/123"
        )) { error in
            XCTAssertEqual(
                error as? CodexAppServerNotificationSurfaceMethodFixture.ParseError,
                .invalidLine(lineNumber: 1)
            )
            XCTAssertFalse(String(describing: error).contains("example.com"))
        }

        XCTAssertThrowsError(try CodexAppServerNotificationSurfaceMethodFixture.parseMethodNames(
            """
            thread/started
            thread/started
            """
        )) { error in
            XCTAssertEqual(
                error as? CodexAppServerNotificationSurfaceMethodFixture.ParseError,
                .duplicateMethod("thread/started")
            )
        }
    }

    func testNotificationAuditCoverageMatchesAcceptedGeneratedSurface() throws {
        let methods = try CodexAppServerNotificationSurfaceMethodFixture.parseMethodNames(
            Self.acceptedGeneratedServerNotificationMethodsFixture
        )
        let report = CodexAppServerNotificationAuditSanitizer.surfaceCoverageForDriftCheck
            .driftReport(acceptedGeneratedMethods: methods)

        XCTAssertFalse(
            report.hasDrift,
            "Unsupported generated notification methods: \(report.unsupportedGeneratedMethods.joined(separator: ", "))"
        )
        XCTAssertEqual(report.acceptedMethodCount, 66)
        XCTAssertEqual(report.coveredGeneratedMethodCount, 66)
        XCTAssertEqual(report.skippedGeneratedMethods, [
            "account/rateLimits/updated",
            "remoteControl/status/changed",
            "thread/tokenUsage/updated",
        ])
        XCTAssertTrue(report.supportedGeneratedMethods.contains("thread/started"))
        XCTAssertTrue(report.supportedGeneratedMethods.contains("account/login/completed"))
    }

    func testNotificationAuditCoverageReportsSyntheticGeneratedDrift() throws {
        var methods = try CodexAppServerNotificationSurfaceMethodFixture.parseMethodNames(
            Self.acceptedGeneratedServerNotificationMethodsFixture
        )
        methods.append("future/notification")
        methods.append("/Users/private/project")
        methods.append("example.com/account/123")

        let report = CodexAppServerNotificationAuditSanitizer.surfaceCoverageForDriftCheck
            .driftReport(acceptedGeneratedMethods: methods)

        XCTAssertTrue(report.hasDrift)
        XCTAssertEqual(report.unsupportedGeneratedMethods, ["future/notification"])
        XCTAssertEqual(report.rejectedGeneratedMethodCount, 2)
        XCTAssertEqual(report.acceptedMethodCount, 67)
        XCTAssertEqual(report.coveredGeneratedMethodCount, 66)
        XCTAssertFalse(report.unsupportedGeneratedMethods.contains("/Users/private/project"))
        XCTAssertFalse(report.unsupportedGeneratedMethods.contains("example.com/account/123"))
    }

    func testNotificationAuditUnknownRuntimeMethodRemainsUnsupportedCountOnly() throws {
        let record = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "future/notification",
            params: [
                "message": "do not store",
                "threadId": "thread-secret",
                "path": "/Users/private/project",
            ] as [String: Any]
        ))

        XCTAssertFalse(record.isSupported)
        XCTAssertEqual(record.safeValues, [:])
        XCTAssertEqual(record.presenceFlags, [])
        XCTAssertEqual(record.unsupportedShapeCount, 1)
        XCTAssertAuditJSON(try encodedAuditJSON(record), excludes: [
            "do not store",
            "thread-secret",
            "/Users/private",
        ])
    }

    func testNotificationAuditSanitizerRecognizesCodex0140NotificationMethods() throws {
        let thread: [String: Any] = [
            "id": "thread-secret",
            "sessionId": "session-secret",
            "forkedFromId": NSNull(),
            "parentThreadId": NSNull(),
            "preview": "private prompt preview",
            "ephemeral": true,
            "modelProvider": "openai",
            "createdAt": 1_777_100_000,
            "updatedAt": 1_777_100_010,
            "status": "running",
            "path": "/Users/private/.codex/thread.jsonl",
            "cwd": "/Users/private/project",
            "cliVersion": "0.140.0",
            "source": "app-server",
            "threadSource": "cli",
            "agentNickname": "private agent",
            "agentRole": "private role",
            "gitInfo": ["branch": "secret-branch"],
            "name": "private thread name",
            "turns": [],
        ]
        let hookRun: [String: Any] = [
            "id": "hook-secret",
            "eventName": "postCommand",
            "handlerType": "shell",
            "executionMode": "blocking",
            "scope": "project",
            "sourcePath": "/Users/private/.codex/config.toml",
            "source": "config",
            "displayOrder": 1,
            "status": "success",
            "statusMessage": "private hook output",
            "startedAt": 1_777_100_000,
            "completedAt": 1_777_100_010,
            "durationMs": 10,
            "entries": [["text": "private hook text"]],
        ]
        let item: [String: Any] = [
            "id": "item-secret",
            "type": "commandExecution",
            "command": "print private",
            "cwd": "/Users/private/project",
            "processId": "process-secret",
            "source": "user",
            "status": "completed",
            "commandActions": [["type": "command", "command": "print private"]],
            "aggregatedOutput": "private output",
            "exitCode": 0,
            "durationMs": 100,
        ]
        let review: [String: Any] = [
            "status": "approved",
            "riskLevel": "low",
            "userAuthorization": "private authorization",
            "rationale": "private rationale",
        ]
        let action: [String: Any] = [
            "type": "command",
            "source": "user",
            "command": "print private",
            "cwd": "/Users/private/project",
        ]

        let fixtures: [(String, [String: Any])] = [
            ("error", ["threadId": "thread-secret", "turnId": "turn-secret", "willRetry": false, "error": ["message": "private error"]]),
            ("thread/started", ["thread": thread]),
            ("thread/archived", ["threadId": "thread-secret"]),
            ("thread/unarchived", ["threadId": "thread-secret"]),
            ("thread/closed", ["threadId": "thread-secret"]),
            ("thread/name/updated", ["threadId": "thread-secret", "threadName": "private name"]),
            ("thread/goal/cleared", ["threadId": "thread-secret"]),
            ("thread/compacted", ["threadId": "thread-secret", "turnId": "turn-secret"]),
            ("skills/changed", [:]),
            ("app/list/updated", ["data": [["id": "app-secret", "name": "Private App", "description": "private", "isAccessible": true]]]),
            ("hook/started", ["threadId": "thread-secret", "turnId": "turn-secret", "run": hookRun]),
            ("hook/completed", ["threadId": "thread-secret", "turnId": "turn-secret", "run": hookRun]),
            ("turn/diff/updated", ["threadId": "thread-secret", "turnId": "turn-secret", "diff": "private diff"]),
            ("turn/plan/updated", ["threadId": "thread-secret", "turnId": "turn-secret", "explanation": "private", "plan": [["step": "private", "status": "pending"]]]),
            ("turn/moderationMetadata", ["threadId": "thread-secret", "turnId": "turn-secret", "metadata": ["private": "metadata"]]),
            ("item/started", ["threadId": "thread-secret", "turnId": "turn-secret", "startedAtMs": 1_777_100_000_000, "item": item]),
            ("item/completed", ["threadId": "thread-secret", "turnId": "turn-secret", "completedAtMs": 1_777_100_001_000, "item": item]),
            ("item/autoApprovalReview/started", ["threadId": "thread-secret", "turnId": "turn-secret", "startedAtMs": 1, "reviewId": "review-secret", "targetItemId": "item-secret", "review": review, "action": action]),
            ("item/autoApprovalReview/completed", ["threadId": "thread-secret", "turnId": "turn-secret", "startedAtMs": 1, "completedAtMs": 2, "reviewId": "review-secret", "targetItemId": "item-secret", "decisionSource": "guardian", "review": review, "action": action]),
            ("rawResponseItem/completed", ["threadId": "thread-secret", "turnId": "turn-secret", "item": ["type": "message", "role": "assistant", "content": []]]),
            ("item/agentMessage/delta", ["threadId": "thread-secret", "turnId": "turn-secret", "itemId": "item-secret", "delta": "private delta"]),
            ("item/plan/delta", ["threadId": "thread-secret", "turnId": "turn-secret", "itemId": "item-secret", "delta": "private delta"]),
            ("item/reasoning/summaryTextDelta", ["threadId": "thread-secret", "turnId": "turn-secret", "itemId": "item-secret", "summaryIndex": 0, "delta": "private reasoning"]),
            ("item/reasoning/summaryPartAdded", ["threadId": "thread-secret", "turnId": "turn-secret", "itemId": "item-secret", "summaryIndex": 0]),
            ("item/reasoning/textDelta", ["threadId": "thread-secret", "turnId": "turn-secret", "itemId": "item-secret", "contentIndex": 0, "delta": "private reasoning"]),
            ("command/exec/outputDelta", ["processId": "process-secret", "stream": "stdout", "deltaBase64": "cHJpdmF0ZQ==", "capReached": false]),
            ("process/outputDelta", ["processHandle": "process-secret", "stream": "stderr", "deltaBase64": "cHJpdmF0ZQ==", "capReached": true]),
            ("process/exited", ["processHandle": "process-secret", "exitCode": 1, "stdout": "private stdout", "stdoutCapReached": false, "stderr": "private stderr", "stderrCapReached": true]),
            ("item/commandExecution/outputDelta", ["threadId": "thread-secret", "turnId": "turn-secret", "itemId": "item-secret", "delta": "private output"]),
            ("item/commandExecution/terminalInteraction", ["threadId": "thread-secret", "turnId": "turn-secret", "itemId": "item-secret", "processId": "process-secret", "stdin": "private input"]),
            ("item/fileChange/outputDelta", ["threadId": "thread-secret", "turnId": "turn-secret", "itemId": "item-secret", "delta": "private patch"]),
            ("item/fileChange/patchUpdated", ["threadId": "thread-secret", "turnId": "turn-secret", "itemId": "item-secret", "changes": [["path": "/Users/private/file.swift", "kind": "update", "diff": "private diff"]]]),
            ("serverRequest/resolved", ["threadId": "thread-secret", "requestId": "request-secret"]),
            ("item/mcpToolCall/progress", ["threadId": "thread-secret", "turnId": "turn-secret", "itemId": "item-secret", "message": "private message"]),
            ("mcpServer/oauthLogin/completed", ["name": "private server", "success": false, "error": "private error"]),
            ("mcpServer/startupStatus/updated", ["threadId": "thread-secret", "name": "private server", "status": "failed", "error": "private error"]),
            ("externalAgentConfig/import/completed", [:]),
            ("fs/changed", ["watchId": "watch-secret", "changedPaths": ["/Users/private/file.swift"]]),
            ("account/login/completed", ["loginId": "login-secret", "success": true, "error": NSNull()]),
            ("fuzzyFileSearch/sessionUpdated", ["sessionId": "session-secret", "query": "private query", "files": [["path": "/Users/private/file.swift"]]]),
            ("fuzzyFileSearch/sessionCompleted", ["sessionId": "session-secret"]),
            ("windows/worldWritableWarning", ["samplePaths": ["/Users/private/world"], "extraCount": 2, "failedScan": false]),
            ("windowsSandbox/setupCompleted", ["mode": "copy", "success": false, "error": "private error"]),
        ]

        for (method, params) in fixtures {
            let record = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(method: method, params: params), method)
            XCTAssertTrue(record.isSupported, method)
        }
    }

    func testNotificationAuditSanitizerCapturesCodex0140LifecycleHookAndMetadataSafely() throws {
        let threadRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "thread/started",
            params: [
                "thread": [
                    "id": "thread-secret",
                    "sessionId": "session-secret",
                    "forkedFromId": "fork-secret",
                    "parentThreadId": "parent-secret",
                    "preview": "private first prompt",
                    "ephemeral": true,
                    "modelProvider": "openai",
                    "createdAt": 1_777_100_000,
                    "updatedAt": 1_777_100_010,
                    "status": "running",
                    "path": "/Users/private/.codex/session.jsonl",
                    "cwd": "/Users/private/project",
                    "source": "app-server",
                    "threadSource": "cli",
                    "agentNickname": "private agent",
                    "agentRole": "private role",
                    "gitInfo": ["branch": "secret-branch"],
                    "name": "private thread",
                    "turns": [["id": "turn-secret"]],
                ],
            ] as [String: Any]
        ))

        XCTAssertTrue(threadRecord.isSupported)
        XCTAssertEqual(threadRecord.safeValues["threadStatus"], "running")
        XCTAssertEqual(threadRecord.safeValues["modelProvider"], "openai")
        XCTAssertEqual(threadRecord.safeValues["source"], "app-server")
        XCTAssertEqual(threadRecord.safeValues["threadSource"], "cli")
        XCTAssertEqual(threadRecord.safeValues["isEphemeral"], "true")
        XCTAssertEqual(threadRecord.safeValues["hasPreview"], "true")
        XCTAssertEqual(threadRecord.safeValues["hasCwd"], "true")
        XCTAssertEqual(threadRecord.safeValues["hasPath"], "true")
        XCTAssertEqual(threadRecord.safeValues["hasGitInfo"], "true")
        XCTAssertEqual(threadRecord.safeValues["hasThreadName"], "true")
        XCTAssertEqual(threadRecord.safeValues["turnCount"], "1")
        XCTAssertEqual(threadRecord.presenceFlags, ["threadId"])
        XCTAssertAuditJSON(try encodedAuditJSON(threadRecord), excludes: [
            "thread-secret",
            "session-secret",
            "private first prompt",
            "/Users/private",
            "secret-branch",
            "private thread",
            "private agent",
            "private role",
        ])

        let hookRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "hook/completed",
            params: [
                "threadId": "thread-secret",
                "turnId": "turn-secret",
                "run": [
                    "id": "hook-secret",
                    "eventName": "postCommand",
                    "handlerType": "shell",
                    "executionMode": "blocking",
                    "scope": "project",
                    "sourcePath": "/Users/private/.codex/config.toml",
                    "source": "config",
                    "displayOrder": 1,
                    "status": "success",
                    "statusMessage": "private status message",
                    "startedAt": 1_777_100_000,
                    "completedAt": 1_777_100_010,
                    "durationMs": 10,
                    "entries": [["text": "private hook output"]],
                ],
            ] as [String: Any]
        ))

        XCTAssertEqual(hookRecord.safeValues["hookEvent"], "postCommand")
        XCTAssertEqual(hookRecord.safeValues["hookHandlerType"], "shell")
        XCTAssertEqual(hookRecord.safeValues["hookExecutionMode"], "blocking")
        XCTAssertEqual(hookRecord.safeValues["hookScope"], "project")
        XCTAssertEqual(hookRecord.safeValues["hookSource"], "config")
        XCTAssertEqual(hookRecord.safeValues["hookStatus"], "success")
        XCTAssertEqual(hookRecord.safeValues["hookEntryCount"], "1")
        XCTAssertEqual(hookRecord.safeValues["hasSourcePath"], "true")
        XCTAssertEqual(hookRecord.safeValues["hasStatusMessage"], "true")
        XCTAssertEqual(hookRecord.safeValues["hasDuration"], "true")
        XCTAssertAuditJSON(try encodedAuditJSON(hookRecord), excludes: [
            "thread-secret",
            "turn-secret",
            "hook-secret",
            "/Users/private",
            "private status message",
            "private hook output",
        ])

        let appRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "app/list/updated",
            params: [
                "data": [
                    [
                        "id": "app-secret-1",
                        "name": "Private App One",
                        "description": "private description",
                        "logoUrl": "https://private.example/logo.png",
                        "installUrl": "https://private.example/install",
                        "isAccessible": true,
                        "isEnabled": true,
                        "pluginDisplayNames": ["Private Plugin"],
                    ],
                    [
                        "id": "app-secret-2",
                        "name": "Private App Two",
                        "description": NSNull(),
                        "isAccessible": false,
                        "isEnabled": false,
                        "pluginDisplayNames": [],
                    ],
                ],
            ] as [String: Any]
        ))

        XCTAssertEqual(appRecord.safeValues["appCount"], "2")
        XCTAssertEqual(appRecord.safeValues["accessibleAppCount"], "1")
        XCTAssertAuditJSON(try encodedAuditJSON(appRecord), excludes: [
            "app-secret",
            "Private App",
            "private description",
            "https://private.example",
            "Private Plugin",
        ])

        let startupRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "mcpServer/startupStatus/updated",
            params: [
                "threadId": "thread-secret",
                "name": "private server",
                "status": "failed",
                "error": "private startup error",
            ] as [String: Any]
        ))

        XCTAssertEqual(startupRecord.safeValues["status"], "failed")
        XCTAssertEqual(startupRecord.safeValues["hasName"], "true")
        XCTAssertEqual(startupRecord.safeValues["hasError"], "true")
        XCTAssertEqual(startupRecord.presenceFlags, ["threadId"])
        XCTAssertAuditJSON(try encodedAuditJSON(startupRecord), excludes: [
            "thread-secret",
            "private server",
            "private startup error",
        ])

        let windowsRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "windowsSandbox/setupCompleted",
            params: [
                "mode": "copy",
                "success": false,
                "error": "private setup error",
            ] as [String: Any]
        ))

        XCTAssertEqual(windowsRecord.safeValues["mode"], "copy")
        XCTAssertEqual(windowsRecord.safeValues["success"], "false")
        XCTAssertEqual(windowsRecord.safeValues["hasError"], "true")
        XCTAssertAuditJSON(try encodedAuditJSON(windowsRecord), excludes: ["private setup error"])
    }

    func testNotificationAuditSanitizerRecordsCodex0140ContentHeavyMethodsAsPresenceOnly() throws {
        let deltaRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "item/agentMessage/delta",
            params: [
                "threadId": "thread-secret",
                "turnId": "turn-secret",
                "itemId": "item-secret",
                "delta": "private streamed assistant text",
            ] as [String: Any]
        ))

        XCTAssertTrue(deltaRecord.isSupported)
        XCTAssertEqual(deltaRecord.safeValues["hasDelta"], "true")
        XCTAssertEqual(Set(deltaRecord.presenceFlags), Set(["threadId", "turnId", "itemId"]))
        XCTAssertAuditJSON(try encodedAuditJSON(deltaRecord), excludes: [
            "thread-secret",
            "turn-secret",
            "item-secret",
            "private streamed assistant text",
        ])

        let planRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "turn/plan/updated",
            params: [
                "threadId": "thread-secret",
                "turnId": "turn-secret",
                "explanation": "private plan explanation",
                "plan": [
                    ["step": "private first step", "status": "pending"],
                    ["step": "private second step", "status": "in_progress"],
                    ["step": "private third step", "status": "completed"],
                ],
            ] as [String: Any]
        ))

        XCTAssertEqual(planRecord.safeValues["hasExplanation"], "true")
        XCTAssertEqual(planRecord.safeValues["planStepCount"], "3")
        XCTAssertEqual(planRecord.safeValues["pendingStepCount"], "1")
        XCTAssertEqual(planRecord.safeValues["inProgressStepCount"], "1")
        XCTAssertEqual(planRecord.safeValues["completedStepCount"], "1")
        XCTAssertAuditJSON(try encodedAuditJSON(planRecord), excludes: [
            "private plan explanation",
            "private first step",
            "private second step",
            "private third step",
        ])

        let processRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "process/exited",
            params: [
                "processHandle": "process-secret",
                "exitCode": 42,
                "stdout": "private stdout bytes",
                "stdoutCapReached": false,
                "stderr": "private stderr bytes",
                "stderrCapReached": true,
            ] as [String: Any]
        ))

        XCTAssertEqual(processRecord.safeValues["hasExitCode"], "true")
        XCTAssertEqual(processRecord.safeValues["hasStdout"], "true")
        XCTAssertEqual(processRecord.safeValues["hasStderr"], "true")
        XCTAssertEqual(processRecord.safeValues["stdoutCapReached"], "false")
        XCTAssertEqual(processRecord.safeValues["stderrCapReached"], "true")
        XCTAssertEqual(processRecord.presenceFlags, ["processHandle"])
        XCTAssertAuditJSON(try encodedAuditJSON(processRecord), excludes: [
            "process-secret",
            "private stdout bytes",
            "private stderr bytes",
            "\"42\"",
        ])

        let patchRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "item/fileChange/patchUpdated",
            params: [
                "threadId": "thread-secret",
                "turnId": "turn-secret",
                "itemId": "item-secret",
                "changes": [
                    ["path": "/Users/private/One.swift", "kind": "add", "diff": "private add diff"],
                    ["path": "/Users/private/Two.swift", "kind": "update", "diff": "private update diff"],
                    ["path": "/Users/private/Three.swift", "kind": "delete", "diff": "private delete diff"],
                ],
            ] as [String: Any]
        ))

        XCTAssertEqual(patchRecord.safeValues["changeCount"], "3")
        XCTAssertEqual(patchRecord.safeValues["addedChangeCount"], "1")
        XCTAssertEqual(patchRecord.safeValues["updatedChangeCount"], "1")
        XCTAssertEqual(patchRecord.safeValues["deletedChangeCount"], "1")
        XCTAssertAuditJSON(try encodedAuditJSON(patchRecord), excludes: [
            "/Users/private",
            "private add diff",
            "private update diff",
            "private delete diff",
        ])

        let fuzzyRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "fuzzyFileSearch/sessionUpdated",
            params: [
                "sessionId": "session-secret",
                "query": "private query",
                "files": [
                    ["path": "/Users/private/One.swift", "score": 0.9],
                    ["path": "/Users/private/Two.swift", "score": 0.7],
                ],
            ] as [String: Any]
        ))

        XCTAssertEqual(fuzzyRecord.safeValues["hasQuery"], "true")
        XCTAssertEqual(fuzzyRecord.safeValues["fileCount"], "2")
        XCTAssertEqual(fuzzyRecord.presenceFlags, ["sessionId"])
        XCTAssertAuditJSON(try encodedAuditJSON(fuzzyRecord), excludes: [
            "session-secret",
            "private query",
            "/Users/private",
        ])
    }

    func testNotificationAuditSanitizerRejectsPrivateFieldsForCodex0140ApprovalAndToolMethods() throws {
        let approvalRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "item/autoApprovalReview/completed",
            params: [
                "threadId": "thread-secret",
                "turnId": "turn-secret",
                "startedAtMs": 1_777_100_000_000,
                "completedAtMs": 1_777_100_001_000,
                "reviewId": "review-secret",
                "targetItemId": "item-secret",
                "decisionSource": "guardian",
                "review": [
                    "status": "approved",
                    "riskLevel": "medium",
                    "userAuthorization": "private authorization",
                    "rationale": "private approval rationale",
                ],
                "action": [
                    "type": "command",
                    "source": "user",
                    "command": "cat /Users/private/secrets.txt",
                    "cwd": "/Users/private/project",
                ],
            ] as [String: Any]
        ))

        XCTAssertEqual(approvalRecord.safeValues["decisionSource"], "guardian")
        XCTAssertEqual(approvalRecord.safeValues["reviewStatus"], "approved")
        XCTAssertEqual(approvalRecord.safeValues["riskLevel"], "medium")
        XCTAssertEqual(approvalRecord.safeValues["hasUserAuthorization"], "true")
        XCTAssertEqual(approvalRecord.safeValues["hasRationale"], "true")
        XCTAssertEqual(approvalRecord.safeValues["actionType"], "command")
        XCTAssertEqual(approvalRecord.safeValues["actionSource"], "user")
        XCTAssertEqual(approvalRecord.safeValues["hasCommand"], "true")
        XCTAssertEqual(approvalRecord.safeValues["hasCwd"], "true")
        XCTAssertEqual(Set(approvalRecord.presenceFlags), Set(["threadId", "turnId", "reviewId", "targetItemId"]))
        XCTAssertAuditJSON(try encodedAuditJSON(approvalRecord), excludes: [
            "thread-secret",
            "turn-secret",
            "review-secret",
            "item-secret",
            "private authorization",
            "private approval rationale",
            "cat /Users/private/secrets.txt",
            "/Users/private/project",
        ])

        let networkApprovalRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "item/autoApprovalReview/completed",
            params: [
                "threadId": "thread-secret",
                "turnId": "turn-secret",
                "startedAtMs": 1,
                "completedAtMs": 2,
                "reviewId": "review-secret",
                "targetItemId": NSNull(),
                "decisionSource": "guardian",
                "review": ["status": "denied", "riskLevel": "high"],
                "action": [
                    "type": "networkAccess",
                    "target": "https://private.example/api",
                    "host": "private.example",
                    "protocol": "https",
                    "port": 443,
                ],
            ] as [String: Any]
        ))

        XCTAssertEqual(networkApprovalRecord.safeValues["actionType"], "networkAccess")
        XCTAssertEqual(networkApprovalRecord.safeValues["protocol"], "https")
        XCTAssertEqual(networkApprovalRecord.safeValues["hasTarget"], "true")
        XCTAssertEqual(networkApprovalRecord.safeValues["hasHost"], "true")
        XCTAssertEqual(networkApprovalRecord.safeValues["hasPort"], "true")
        XCTAssertEqual(Set(networkApprovalRecord.presenceFlags), Set(["threadId", "turnId", "reviewId"]))
        XCTAssertAuditJSON(try encodedAuditJSON(networkApprovalRecord), excludes: [
            "https://private.example",
            "private.example",
            "\"443\"",
        ])

        let progressRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "item/mcpToolCall/progress",
            params: [
                "threadId": "thread-secret",
                "turnId": "turn-secret",
                "itemId": "item-secret",
                "message": "private progress message",
            ] as [String: Any]
        ))

        XCTAssertEqual(progressRecord.safeValues["hasMessage"], "true")
        XCTAssertEqual(Set(progressRecord.presenceFlags), Set(["threadId", "turnId", "itemId"]))
        XCTAssertAuditJSON(try encodedAuditJSON(progressRecord), excludes: [
            "thread-secret",
            "turn-secret",
            "item-secret",
            "private progress message",
        ])

        let accountLoginRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "account/login/completed",
            params: [
                "loginId": "login-secret",
                "success": false,
                "error": "private login error",
            ] as [String: Any]
        ))

        XCTAssertEqual(accountLoginRecord.safeValues["success"], "false")
        XCTAssertEqual(accountLoginRecord.safeValues["hasError"], "true")
        XCTAssertEqual(accountLoginRecord.presenceFlags, ["loginId"])
        XCTAssertAuditJSON(try encodedAuditJSON(accountLoginRecord), excludes: [
            "login-secret",
            "private login error",
        ])

        let requestRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "serverRequest/resolved",
            params: [
                "threadId": "thread-secret",
                "requestId": "request-secret",
            ] as [String: Any]
        ))

        XCTAssertEqual(requestRecord.safeValues, [:])
        XCTAssertEqual(Set(requestRecord.presenceFlags), Set(["threadId", "requestId"]))
        XCTAssertAuditJSON(try encodedAuditJSON(requestRecord), excludes: [
            "thread-secret",
            "request-secret",
        ])
    }

    func testNotificationAuditSanitizerRejectsUnknownCodex0140ProviderAndEnumValues() throws {
        let threadRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "thread/started",
            params: [
                "thread": [
                    "id": "thread-secret",
                    "status": "privateThreadStatus",
                    "modelProvider": "privateProvider",
                    "source": "privateSource",
                    "threadSource": "privateThreadSource",
                ],
            ] as [String: Any]
        ))

        XCTAssertNil(threadRecord.safeValues["threadStatus"])
        XCTAssertNil(threadRecord.safeValues["modelProvider"])
        XCTAssertNil(threadRecord.safeValues["source"])
        XCTAssertNil(threadRecord.safeValues["threadSource"])
        XCTAssertEqual(threadRecord.safeValues["hasModelProvider"], "true")
        XCTAssertAuditJSON(try encodedAuditJSON(threadRecord), excludes: [
            "thread-secret",
            "privateThreadStatus",
            "privateProvider",
            "privateSource",
            "privateThreadSource",
        ])

        let hookRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "hook/completed",
            params: [
                "threadId": "thread-secret",
                "turnId": "turn-secret",
                "run": [
                    "eventName": "privateHookEvent",
                    "handlerType": "privateHandler",
                    "executionMode": "privateMode",
                    "scope": "privateScope",
                    "source": "privateSource",
                    "status": "privateStatus",
                ],
            ] as [String: Any]
        ))

        XCTAssertNil(hookRecord.safeValues["hookEvent"])
        XCTAssertNil(hookRecord.safeValues["hookHandlerType"])
        XCTAssertNil(hookRecord.safeValues["hookExecutionMode"])
        XCTAssertNil(hookRecord.safeValues["hookScope"])
        XCTAssertNil(hookRecord.safeValues["hookSource"])
        XCTAssertNil(hookRecord.safeValues["hookStatus"])
        XCTAssertAuditJSON(try encodedAuditJSON(hookRecord), excludes: [
            "thread-secret",
            "turn-secret",
            "privateHookEvent",
            "privateHandler",
            "privateMode",
            "privateScope",
            "privateSource",
            "privateStatus",
        ])

        let settingsRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "thread/settings/updated",
            params: [
                "threadId": "thread-secret",
                "threadSettings": [
                    "modelProvider": "privateProvider",
                    "effort": "privateEffort",
                    "approvalPolicy": ["type": "privatePolicy"],
                    "approvalsReviewer": "privateReviewer",
                    "sandboxPolicy": ["type": "privateSandbox"],
                    "collaborationMode": ["mode": "privateMode"],
                ],
            ] as [String: Any]
        ))

        XCTAssertNil(settingsRecord.safeValues["modelProvider"])
        XCTAssertNil(settingsRecord.safeValues["effort"])
        XCTAssertNil(settingsRecord.safeValues["approvalPolicy"])
        XCTAssertNil(settingsRecord.safeValues["approvalsReviewer"])
        XCTAssertNil(settingsRecord.safeValues["sandboxPolicy"])
        XCTAssertNil(settingsRecord.safeValues["collaborationMode"])
        XCTAssertEqual(settingsRecord.safeValues["hasModelProvider"], "true")
        XCTAssertAuditJSON(try encodedAuditJSON(settingsRecord), excludes: [
            "thread-secret",
            "privateProvider",
            "privateEffort",
            "privatePolicy",
            "privateReviewer",
            "privateSandbox",
            "privateMode",
        ])
    }

    @MainActor
    func testAppServerClientEmitsNotificationAuditWithoutDecodingPayload() throws {
        let client = CodexAppServerClient()
        var diagnosticEvents: [CodexAppServerAuditDiagnosticEvent] = []
        client.onAppServerAuditDiagnosticEvent = { diagnosticEvents.append($0) }

        try client.handleIncomingMessage(data: Data(
            """
            {
              "method": "model/rerouted",
              "params": {
                "threadId": "thread-secret",
                "turnId": "turn-secret",
                "fromModel": "gpt-5.4",
                "toModel": "gpt-5.5",
                "reason": "highRiskCyberActivity",
                "message": "do not store"
              }
            }
            """.utf8
        ))

        XCTAssertTrue(diagnosticEvents.contains(.inboundMethod("model/rerouted")))
        let auditEvent = try XCTUnwrap(diagnosticEvents.compactMap { event -> CodexAppServerNotificationAuditRecord? in
            if case .notificationAudit(let record) = event {
                return record
            }
            return nil
        }.first)

        XCTAssertEqual(auditEvent.method, "model/rerouted")
        XCTAssertEqual(auditEvent.safeValues["fromModel"], "gpt-5.4")
        XCTAssertEqual(auditEvent.safeValues["toModel"], "gpt-5.5")
        XCTAssertGreaterThan(auditEvent.rejectedUnsafeFieldCount, 0)
    }

    func testProfileTokenUsageResponseDecodesSanitizedStatsOnly() throws {
        let response = try JSONDecoder().decode(
            CodexProfileTokenUsageResponse.self,
            from: Data(
                """
                {
                  "profile": {
                    "display_name": "Do Not Store",
                    "username": "private-user",
                    "profile_picture_url": "https://example.com/private.png"
                  },
                  "stats": {
                    "lifetime_tokens": 17220508070,
                    "peak_daily_tokens": 987654321,
                    "daily_usage_buckets": [
                      {"start_date": "2026-05-29", "tokens": 123},
                      {"start_date": "2026-05-30", "tokens": 456},
                      {"start_date": "bad value", "tokens": 999}
                    ]
                  }
                }
                """.utf8
            )
        )

        let snapshot = response.domainSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertEqual(snapshot.lifetimeTokens, 17_220_508_070)
        XCTAssertEqual(snapshot.peakDailyTokens, 987_654_321)
        XCTAssertEqual(snapshot.dailyBuckets, [
            CodexProfileTokenDailyBucket(date: "2026-05-29", tokens: 123),
            CodexProfileTokenDailyBucket(date: "2026-05-30", tokens: 456),
        ])

        let encodedSnapshot = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8) ?? ""
        XCTAssertFalse(encodedSnapshot.contains("Do Not Store"))
        XCTAssertFalse(encodedSnapshot.contains("private-user"))
        XCTAssertFalse(encodedSnapshot.contains("profile_picture_url"))
    }

    func testProfileTokenUsageResponseAllowsMissingStats() throws {
        let response = try JSONDecoder().decode(
            CodexProfileTokenUsageResponse.self,
            from: Data(#"{"profile":{"display_name":"Private"}}"#.utf8)
        )

        let snapshot = response.domainSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertNil(snapshot.lifetimeTokens)
        XCTAssertNil(snapshot.peakDailyTokens)
        XCTAssertTrue(snapshot.dailyBuckets.isEmpty)
    }

    func testAccountTokenUsageResponseDecodesSanitizedStatsOnly() throws {
        let response = try JSONDecoder().decode(
            CodexAccountTokenUsageResponse.self,
            from: Data(
                """
                {
                  "account": {
                    "id": "acct-private",
                    "email": "private@example.com"
                  },
                  "summary": {
                    "lifetimeTokens": 17220508070,
                    "peakDailyTokens": 987654321,
                    "longestRunningTurnSec": 3661,
                    "currentStreakDays": 3,
                    "longestStreakDays": 19
                  },
                  "dailyUsageBuckets": [
                    {"startDate": "2026-05-29", "tokens": 123},
                    {"startDate": "2026-05-30", "tokens": 456},
                    {"startDate": "bad value", "tokens": 999}
                  ]
                }
                """.utf8
            )
        )

        let snapshot = response.domainSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertEqual(snapshot.lifetimeTokens, 17_220_508_070)
        XCTAssertEqual(snapshot.peakDailyTokens, 987_654_321)
        XCTAssertEqual(snapshot.longestRunningTurnSeconds, 3_661)
        XCTAssertEqual(snapshot.currentStreakDays, 3)
        XCTAssertEqual(snapshot.longestStreakDays, 19)
        XCTAssertEqual(snapshot.dailyBuckets, [
            CodexProfileTokenDailyBucket(date: "2026-05-29", tokens: 123),
            CodexProfileTokenDailyBucket(date: "2026-05-30", tokens: 456),
        ])

        let encodedSnapshot = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8) ?? ""
        XCTAssertFalse(encodedSnapshot.contains("acct-private"))
        XCTAssertFalse(encodedSnapshot.contains("private@example.com"))
        XCTAssertFalse(encodedSnapshot.contains("account"))
    }

    func testAccountTokenUsageResponseAllowsNullSummaryAndBuckets() throws {
        let response = try JSONDecoder().decode(
            CodexAccountTokenUsageResponse.self,
            from: Data(#"{"summary":null,"dailyUsageBuckets":null}"#.utf8)
        )

        let snapshot = response.domainSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertNil(snapshot.lifetimeTokens)
        XCTAssertNil(snapshot.peakDailyTokens)
        XCTAssertNil(snapshot.longestRunningTurnSeconds)
        XCTAssertNil(snapshot.currentStreakDays)
        XCTAssertNil(snapshot.longestStreakDays)
        XCTAssertTrue(snapshot.dailyBuckets.isEmpty)
    }

    func testResetCreditsResponseDecodesAvailableCreditsOnlyAndIgnoresPrivateFields() throws {
        let response = try JSONDecoder().decode(
            CodexResetCreditsResponse.self,
            from: Data(
                """
                {
                  "available_count": 2,
                  "total_earned_count": 10,
                  "credits": [
                    {
                      "id": "credit-private-id",
                      "profile_user_id": "user-private",
                      "profile_image_url": "https://example.com/private.png",
                      "description": "do not store this",
                      "title": "Full reset (Weekly + 5 hr)",
                      "reset_type": "codex_rate_limits",
                      "status": "available",
                      "granted_at": "2026-06-26T23:58:05.557369Z",
                      "expires_at": "2026-07-26T23:58:05.557369Z",
                      "redeemed_at": null
                    },
                    {
                      "title": "Used reset",
                      "reset_type": "codex_rate_limits",
                      "status": "redeemed",
                      "granted_at": "2026-06-01T00:00:00Z",
                      "expires_at": "2026-07-01T00:00:00Z",
                      "redeemed_at": "2026-06-03T00:00:00Z"
                    },
                    {
                      "title": "https://private.example/reset",
                      "reset_type": "bad value",
                      "status": "available",
                      "granted_at": "not a date",
                      "expires_at": "2026-07-01T00:00:00Z"
                    }
                  ]
                }
                """.utf8
            )
        )

        let snapshot = response.domainSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertEqual(snapshot.availableCount, 2)
        XCTAssertEqual(snapshot.credits.count, 1)
        XCTAssertEqual(snapshot.credits[0].title, "Full reset (Weekly + 5 hr)")
        XCTAssertEqual(snapshot.credits[0].resetType, "codex_rate_limits")
        XCTAssertEqual(snapshot.credits[0].status, "available")
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(
            snapshot.credits[0].grantedAt,
            fractionalFormatter.date(from: "2026-06-26T23:58:05.557369Z")
        )
        XCTAssertNil(snapshot.credits[0].redeemedAt)

        let encodedSnapshot = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8) ?? ""
        XCTAssertFalse(encodedSnapshot.contains("credit-private-id"))
        XCTAssertFalse(encodedSnapshot.contains("user-private"))
        XCTAssertFalse(encodedSnapshot.contains("profile_image_url"))
        XCTAssertFalse(encodedSnapshot.contains("do not store"))
        XCTAssertFalse(encodedSnapshot.contains("Used reset"))
    }

    @MainActor
    func testAppServerClientPrefersAccountUsageReadForProfileTokenSnapshot() async throws {
        var requestedMethods: [String] = []
        let client = CodexAppServerClient(
            ensureConnectedOverride: {},
            sendRequestOverride: { method, _ in
                requestedMethods.append(method)
                XCTAssertEqual(method, "account/usage/read")
                return [
                    "summary": [
                        "lifetimeTokens": Int64(1_000),
                        "peakDailyTokens": Int64(250),
                        "longestRunningTurnSec": Int64(90),
                        "currentStreakDays": Int64(2),
                        "longestStreakDays": Int64(5),
                    ],
                    "dailyUsageBuckets": [
                        [
                            "startDate": "2026-05-30",
                            "tokens": Int64(10),
                        ],
                    ],
                ]
            }
        )

        let snapshot = try await client.profileTokenUsageSnapshot()

        XCTAssertEqual(requestedMethods, ["account/usage/read"])
        XCTAssertEqual(snapshot.lifetimeTokens, 1_000)
        XCTAssertEqual(snapshot.peakDailyTokens, 250)
        XCTAssertEqual(snapshot.longestRunningTurnSeconds, 90)
        XCTAssertEqual(snapshot.currentStreakDays, 2)
        XCTAssertEqual(snapshot.longestStreakDays, 5)
        XCTAssertEqual(snapshot.dailyBuckets.map(\.tokens), [10])
    }

    @MainActor
    func testAppServerClientFallsBackToProfileHTTPWhenAccountUsageReadFails() async throws {
        let endpoint = URL(string: "https://example.com/wham/profiles/me")!
        var requestedMethods: [String] = []
        var authorizationHeaders: [String?] = []
        let profileClient = CodexProfileTokenUsageHTTPClient(
            endpoint: endpoint,
            responseLoader: { request in
                authorizationHeaders.append(request.value(forHTTPHeaderField: "Authorization"))
                return (
                    Data(
                        """
                        {
                          "stats": {
                            "lifetime_tokens": 1000,
                            "peak_daily_tokens": 250,
                            "daily_usage_buckets": [
                              {"start_date": "2026-05-30", "tokens": 10}
                            ]
                          }
                        }
                        """.utf8
                    ),
                    HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let client = CodexAppServerClient(
            ensureConnectedOverride: {},
            sendRequestOverride: { method, _ in
                requestedMethods.append(method)
                if method == "account/usage/read" {
                    throw CodexClientError.jsonRPCError("Method not found")
                }
                if method == "getAuthStatus" {
                    return [
                        "authMethod": "chatgpt",
                        "authToken": "fallback-token",
                        "requiresOpenaiAuth": true,
                    ]
                }
                throw CodexClientError.invalidResponse
            },
            profileTokenUsageHTTPClient: profileClient
        )

        let snapshot = try await client.profileTokenUsageSnapshot()

        XCTAssertEqual(requestedMethods, ["account/usage/read", "getAuthStatus"])
        XCTAssertEqual(authorizationHeaders, ["Bearer fallback-token"])
        XCTAssertEqual(snapshot.lifetimeTokens, 1_000)
        XCTAssertEqual(snapshot.peakDailyTokens, 250)
        XCTAssertEqual(snapshot.dailyBuckets.map(\.tokens), [10])
        XCTAssertNil(snapshot.longestRunningTurnSeconds)
        XCTAssertNil(snapshot.currentStreakDays)
        XCTAssertNil(snapshot.longestStreakDays)
    }

    @MainActor
    func testResetCreditHTTPClientRetriesUnauthorizedWithRefreshedAuth() async throws {
        let endpoint = URL(string: "https://example.com/wham/rate-limit-reset-credits")!
        var refreshRequests: [Bool] = []
        var authorizationHeaders: [String?] = []
        var loadCount = 0
        let client = CodexResetCreditHTTPClient(
            endpoint: endpoint,
            responseLoader: { request in
                loadCount += 1
                authorizationHeaders.append(request.value(forHTTPHeaderField: "Authorization"))
                if loadCount == 1 {
                    return (
                        Data(),
                        HTTPURLResponse(url: endpoint, statusCode: 401, httpVersion: nil, headerFields: nil)!
                    )
                }

                return (
                    Data(
                        """
                        {
                          "available_count": 1,
                          "credits": [
                            {
                              "title": "Usage reset",
                              "reset_type": "codex_rate_limits",
                              "status": "available",
                              "granted_at": "2026-06-26T23:58:05Z",
                              "expires_at": "2026-07-26T23:58:05Z"
                            }
                          ]
                        }
                        """.utf8
                    ),
                    HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = try await client.fetch { refreshToken in
            refreshRequests.append(refreshToken)
            return refreshToken ? "new-token" : "old-token"
        }

        XCTAssertEqual(refreshRequests, [false, true])
        XCTAssertEqual(authorizationHeaders, ["Bearer old-token", "Bearer new-token"])
        XCTAssertEqual(snapshot.availableCount, 1)
        XCTAssertEqual(snapshot.credits.map(\.title), ["Usage reset"])
    }

    @MainActor
    func testAppServerClientFetchesResetCreditsThroughAuthStatus() async throws {
        let endpoint = URL(string: "https://example.com/wham/rate-limit-reset-credits")!
        var requestedMethods: [String] = []
        var authorizationHeaders: [String?] = []
        let resetClient = CodexResetCreditHTTPClient(
            endpoint: endpoint,
            responseLoader: { request in
                authorizationHeaders.append(request.value(forHTTPHeaderField: "Authorization"))
                return (
                    Data(
                        """
                        {
                          "available_count": 1,
                          "credits": [
                            {
                              "title": "Full reset",
                              "reset_type": "codex_rate_limits",
                              "status": "available",
                              "granted_at": "2026-07-01T20:16:33Z",
                              "expires_at": "2026-07-31T20:16:33Z"
                            }
                          ]
                        }
                        """.utf8
                    ),
                    HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let client = CodexAppServerClient(
            ensureConnectedOverride: {},
            sendRequestOverride: { method, _ in
                requestedMethods.append(method)
                XCTAssertEqual(method, "getAuthStatus")
                return [
                    "authMethod": "chatgpt",
                    "authToken": "reset-token",
                    "requiresOpenaiAuth": true,
                ]
            },
            resetCreditHTTPClient: resetClient
        )

        let snapshot = try await client.resetCreditSnapshot()

        XCTAssertEqual(requestedMethods, ["getAuthStatus"])
        XCTAssertEqual(authorizationHeaders, ["Bearer reset-token"])
        XCTAssertEqual(snapshot.credits.map(\.title), ["Full reset"])
    }

    @MainActor
    func testProfileTokenUsageHTTPClientRetriesUnauthorizedWithRefreshedAuth() async throws {
        let endpoint = URL(string: "https://example.com/wham/profiles/me")!
        var refreshRequests: [Bool] = []
        var authorizationHeaders: [String?] = []
        var loadCount = 0
        let client = CodexProfileTokenUsageHTTPClient(
            endpoint: endpoint,
            responseLoader: { request in
                loadCount += 1
                authorizationHeaders.append(request.value(forHTTPHeaderField: "Authorization"))
                if loadCount == 1 {
                    return (
                        Data(),
                        HTTPURLResponse(url: endpoint, statusCode: 401, httpVersion: nil, headerFields: nil)!
                    )
                }

                return (
                    Data(
                        """
                        {
                          "stats": {
                            "lifetime_tokens": 1000,
                            "peak_daily_tokens": 250,
                            "daily_usage_buckets": [
                              {"start_date": "2026-05-30", "tokens": 10}
                            ]
                          }
                        }
                        """.utf8
                    ),
                    HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = try await client.fetch { refreshToken in
            refreshRequests.append(refreshToken)
            return refreshToken ? "new-token" : "old-token"
        }

        XCTAssertEqual(refreshRequests, [false, true])
        XCTAssertEqual(authorizationHeaders, ["Bearer old-token", "Bearer new-token"])
        XCTAssertEqual(snapshot.lifetimeTokens, 1_000)
        XCTAssertEqual(snapshot.peakDailyTokens, 250)
        XCTAssertEqual(snapshot.dailyBuckets.map(\.tokens), [10])
    }

    private static let acceptedGeneratedServerNotificationMethodsFixture = """
    error
    thread/started
    thread/status/changed
    thread/archived
    thread/unarchived
    thread/closed
    skills/changed
    thread/name/updated
    thread/goal/updated
    thread/goal/cleared
    thread/settings/updated
    thread/tokenUsage/updated
    turn/started
    hook/started
    turn/completed
    hook/completed
    turn/diff/updated
    turn/plan/updated
    item/started
    item/autoApprovalReview/started
    item/autoApprovalReview/completed
    item/completed
    rawResponseItem/completed
    item/agentMessage/delta
    item/plan/delta
    command/exec/outputDelta
    process/outputDelta
    process/exited
    item/commandExecution/outputDelta
    item/commandExecution/terminalInteraction
    item/fileChange/outputDelta
    item/fileChange/patchUpdated
    serverRequest/resolved
    item/mcpToolCall/progress
    mcpServer/oauthLogin/completed
    mcpServer/startupStatus/updated
    account/updated
    account/rateLimits/updated
    app/list/updated
    remoteControl/status/changed
    externalAgentConfig/import/completed
    fs/changed
    item/reasoning/summaryTextDelta
    item/reasoning/summaryPartAdded
    item/reasoning/textDelta
    thread/compacted
    model/rerouted
    model/verification
    turn/moderationMetadata
    warning
    guardianWarning
    deprecationNotice
    configWarning
    fuzzyFileSearch/sessionUpdated
    fuzzyFileSearch/sessionCompleted
    thread/realtime/started
    thread/realtime/itemAdded
    thread/realtime/transcript/delta
    thread/realtime/transcript/done
    thread/realtime/outputAudio/delta
    thread/realtime/sdp
    thread/realtime/error
    thread/realtime/closed
    windows/worldWritableWarning
    windowsSandbox/setupCompleted
    account/login/completed
    """

    private func decodeTokenUsageModel(
        extraRoot: String = "",
        extraTokenUsage: String = ""
    ) throws -> String? {
        let data = Data(
            """
            {
              "threadId": "thread-123",
              "turnId": "turn-456",
              "tokenUsage": {
                "last": {
                  "inputTokens": 1200,
                  "cachedInputTokens": 900,
                  "outputTokens": 300,
                  "reasoningOutputTokens": 40,
                  "totalTokens": 1500
                },
                "total": {
                  "inputTokens": 10000,
                  "cachedInputTokens": 7000,
                  "outputTokens": 2000,
                  "reasoningOutputTokens": 400,
                  "totalTokens": 12000
                },
                "modelContextWindow": 258400
                \(extraTokenUsage)
              }
              \(extraRoot)
            }
            """.utf8
        )

        return try JSONDecoder()
            .decode(ThreadTokenUsageUpdatedNotificationPayload.self, from: data)
            .toDomainNotification()
            .model
    }

    private func jsonObject(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func encodedAuditJSON(_ record: CodexAppServerNotificationAuditRecord) throws -> String {
        String(data: try JSONEncoder().encode(record), encoding: .utf8) ?? ""
    }

    private func XCTAssertAuditJSON(
        _ json: String,
        excludes privateValues: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for privateValue in privateValues {
            XCTAssertFalse(json.contains(privateValue), "Stored private value: \(privateValue)", file: file, line: line)
        }
    }

    private func auditField(_ keyPath: String, in audit: CodexTokenUsagePayloadAudit) throws -> CodexTokenPayloadAuditField {
        try XCTUnwrap(audit.fields.first { $0.keyPath == keyPath })
    }
}
