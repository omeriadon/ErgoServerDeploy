//
//  routes.swift
//  ErgoServer
//
//  Created by Adon Omeri on 5/11/2026.
//

import ErgoProtocol
import Vapor

/// Every path comes from `ErgoProtocol.Path`, so the app and the server can't disagree
func routes(_ app: Application) throws {
	app.post(ErgoProtocol.Path.accounts.pathComponents, use: AccountController.create)
	// Apple's, not the app's, so the path isn't in ErgoProtocol
	app.on(
		.POST,
		AppleNotificationController.path.pathComponents,
		body: .collect(maxSize: ByteCount(value: AppleNotificationController.maxBytes)),
		use: AppleNotificationController.receive
	)

	// The CLI's, not the app's: the token in the path is all the auth a run's tools have
	let askTool: [PathComponent] = ErgoProtocol.Path.askTools.pathComponents + [":token"]
	app.on(.POST, askTool, body: .collect(maxSize: "1mb"), use: AskToolController.receive)
	app.get(askTool, use: AskToolController.refuse)
	app.delete(askTool, use: AskToolController.refuse)

	// Not the app's either: Apple's CDN and browsers
	let joinPage: [PathComponent] = ErgoProtocol.Path.join.pathComponents + [":token"]
	app.get(ErgoProtocol.Path.appleAppSiteAssociation.pathComponents, use: JoinController.association)
	app.get(joinPage, use: JoinController.page)
	app.get(ErgoProtocol.Path.privacyPolicy.pathComponents) { _ async throws -> Response in LegalController.page(.privacyPolicy) }
	app.get(ErgoProtocol.Path.terms.pathComponents) { _ async throws -> Response in LegalController.page(.terms) }
	// Someone may not have an account yet when they open a link
	app.post(ErgoProtocol.Path.invitePreview.pathComponents, use: BoardSharingController.preview)

	let signedIn = app.grouped(AccountAuthenticator())
	let connection: [PathComponent] = ErgoProtocol.Path.connections.pathComponents + [":provider"]

	signedIn.delete(ErgoProtocol.Path.account.pathComponents, use: AccountController.delete)
	signedIn.delete(ErgoProtocol.Path.accountToken.pathComponents, use: AccountController.signOut)
	signedIn.post(ErgoProtocol.Path.appleSignIn.pathComponents, use: AccountController.signInWithApple)
	signedIn.post(ErgoProtocol.Path.register.pathComponents, use: EmailController.register)
	signedIn.post(ErgoProtocol.Path.logIn.pathComponents, use: EmailController.logIn)
	signedIn.post(ErgoProtocol.Path.password.pathComponents, use: EmailController.changePassword)

	// An anonymous account uses the server's own model too, so these don't wait for a sign-in
	signedIn.get(ErgoProtocol.Path.usage.pathComponents, use: UsageController.status)
	// A transaction carries Apple's certificates, more than Vapor's default
	signedIn.on(.POST, ErgoProtocol.Path.plan.pathComponents, body: .collect(maxSize: "64kb"), use: UsageController.plan)
	signedIn.on(.POST, ErgoProtocol.Path.deviceClaim.pathComponents, body: .collect(maxSize: "64kb"), use: UsageController.claim)

	signedIn.get(ErgoProtocol.Path.connections.pathComponents, use: ConnectionController.list)
	// An auth.json is a few kilobytes, more than Vapor's default
	signedIn.on(.PUT, connection, body: .collect(maxSize: "64kb"), use: ConnectionController.connect)
	signedIn.delete(connection, use: ConnectionController.disconnect)

	signedIn.webSocket(ErgoProtocol.Path.deviceLogin.pathComponents) { request, socket in
		await CodexDeviceLogin(request: request, socket: socket).run()
	}
	// Not the async upgrade, which starts on another thread and could miss the request
	signedIn.webSocket(ErgoProtocol.Path.translate.pathComponents, maxFrameSize: .init(integerLiteral: 1 << 18)) { request, socket in
		let translate = TranslateSocket(request: request, socket: socket)
		Task {
			await translate.run()
		}
	}

	let synced = signedIn.grouped(RequireSignedIn())
	// Not the async upgrade, like translate. A whole conversation can be sizeable.
	synced.webSocket(ErgoProtocol.Path.ask.pathComponents, maxFrameSize: .init(integerLiteral: 1 << 21)) { request, socket in
		let ask = AskSocket(request: request, socket: socket)
		Task {
			await ask.run()
		}
	}
	synced.on(.POST, ErgoProtocol.Path.sync.pathComponents, body: .collect(maxSize: ByteCount(value: SyncLimit.requestBytes)), use: SyncController.sync)
	// Registers straight away on the socket's event loop, so a push just after the upgrade can't be missed
	synced.webSocket(ErgoProtocol.Path.syncLive.pathComponents, maxFrameSize: .init(integerLiteral: 1 << 12)) { request, socket in
		guard let account = try? request.accountID, let token = try? request.tokenID else {
			request.logger.warning("A live sync socket opened without an account")
			return socket.close(code: .policyViolation, promise: nil)
		}
		socket.logClosing("Sync live", logger: request.logger)
		request.ergo.live.listen(socket, account: account, token: token, pingInterval: request.ergo.config.pingInterval)
	}

	let boardInvites = ErgoProtocol.Path.boardInvites(":board").pathComponents
	let boardMember = ErgoProtocol.Path.boardMember(":board", ":member").pathComponents
	synced.post(boardInvites, use: BoardSharingController.createInvite)
	synced.delete(boardInvites, use: BoardSharingController.revokeInvites)
	synced.post(boardMember, use: BoardSharingController.updateMember)
	synced.delete(boardMember, use: BoardSharingController.removeMember)
	synced.delete(ErgoProtocol.Path.boardShare(":board").pathComponents, use: BoardSharingController.stopSharing)
	synced.post(ErgoProtocol.Path.boardReport(":board").pathComponents, use: BoardSharingController.report)
	synced.post(ErgoProtocol.Path.inviteAccept.pathComponents, use: BoardSharingController.accept)
	let boardAnalysis = ErgoProtocol.Path.boardAnalysis(":board").pathComponents
	synced.on(.POST, boardAnalysis, body: .collect(maxSize: "2mb"), use: BoardAnalysisController.start)
	synced.delete(boardAnalysis, use: BoardAnalysisController.stop)
	synced.put(ErgoProtocol.Path.pushDevice.pathComponents, use: PushController.register)
	synced.delete(ErgoProtocol.Path.pushDevice.pathComponents, use: PushController.unregister)
}
