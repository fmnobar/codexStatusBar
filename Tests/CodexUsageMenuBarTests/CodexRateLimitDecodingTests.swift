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

    private func auditField(_ keyPath: String, in audit: CodexTokenUsagePayloadAudit) throws -> CodexTokenPayloadAuditField {
        try XCTUnwrap(audit.fields.first { $0.keyPath == keyPath })
    }
}
