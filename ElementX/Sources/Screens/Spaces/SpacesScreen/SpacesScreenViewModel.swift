//
// Copyright 2025 Element Creations Ltd.
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias SpacesScreenViewModelType = StateStoreViewModelV2<SpacesScreenViewState, SpacesScreenViewAction>

class SpacesScreenViewModel: SpacesScreenViewModelType, SpacesScreenViewModelProtocol {
    private let clientProxy: ClientProxyProtocol
    private let spaceServiceProxy: SpaceServiceProxyProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    private var circleMemberCancellables = Set<AnyCancellable>()
    private var knownDirectRooms = [String: String]()
    private var pendingDirectRoomUserIDs = Set<String>()

    private let actionsSubject: PassthroughSubject<SpacesScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<SpacesScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(userSession: UserSessionProtocol,
         selectedSpacePublisher: CurrentValuePublisher<String?, Never>,
         userIndicatorController: UserIndicatorControllerProtocol) {
        clientProxy = userSession.clientProxy
        spaceServiceProxy = userSession.clientProxy.spaceService
        self.userIndicatorController = userIndicatorController

        super.init(initialViewState: SpacesScreenViewState(userProfile: userSession.clientProxy.userProfilePublisher.value,
                                                           topLevelSpaces: spaceServiceProxy.topLevelSpacesPublisher.value),
                   mediaProvider: userSession.mediaProvider)

        spaceServiceProxy.topLevelSpacesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] spaces in
                guard let self else { return }
                state.topLevelSpaces = spaces

                if let selectedSpaceID = state.selectedSpaceID,
                   spaces.contains(where: { $0.id == selectedSpaceID }) {
                    return
                }

                state.selectedSpaceID = spaces.first?.id
                if let selectedSpaceID = state.selectedSpaceID {
                    Task { await self.loadMembers(for: selectedSpaceID) }
                } else {
                    state.circleMembers = []
                }
            }
            .store(in: &cancellables)

        selectedSpacePublisher
            .sink { [weak self] selectedSpaceID in
                guard let self else { return }
                if let selectedSpaceID {
                    state.selectedSpaceID = selectedSpaceID
                    Task { await self.loadMembers(for: selectedSpaceID) }
                }
            }
            .store(in: &cancellables)

        userSession.clientProxy.userProfilePublisher
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.userProfile, on: self)
            .store(in: &cancellables)

        if let selectedSpaceID = state.selectedSpaceID ?? state.topLevelSpaces.first?.id {
            state.selectedSpaceID = selectedSpaceID
            Task { await loadMembers(for: selectedSpaceID) }
        }
    }

    // MARK: - Public

    override func process(viewAction: SpacesScreenViewAction) {
        MXLog.info("View model: received view action: \(viewAction)")

        switch viewAction {
        case .spaceAction(.select(let spaceServiceRoom)):
            Task { await selectSpace(spaceServiceRoom) }
        case .spaceAction(.join):
            fatalError("There shouldn't be any unjoined spaces in the joined spaces list.")
        case .selectCircle(let spaceServiceRoom):
            state.selectedSpaceID = spaceServiceRoom.id
            state.bindings.searchQuery = ""
            Task { await loadMembers(for: spaceServiceRoom.id) }
        case .selectCircleMember(let member):
            Task { await openDirectChat(with: member) }
        case .showSettings:
            actionsSubject.send(.showSettings)
        case .createSpace:
            actionsSubject.send(.showCreateSpace)
        }
    }

    // MARK: - Private

    private func selectSpace(_ spaceServiceRoom: SpaceServiceRoom) async {
        switch await spaceServiceProxy.spaceRoomList(spaceID: spaceServiceRoom.id) {
        case .success(let spaceRoomListProxy):
            actionsSubject.send(.selectSpace(spaceRoomListProxy))
        case .failure(let error):
            MXLog.error("Unable to select space: \(error)")
            showFailureIndicator()
        }
    }

    private func loadMembers(for roomID: String) async {
        state.circleMembers = nil
        circleMemberCancellables.removeAll()

        guard case let .joined(roomProxy) = await clientProxy.roomForIdentifier(roomID) else {
            state.circleMembers = []
            return
        }

        roomProxy.membersPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] members in
                guard let self else { return }
                state.circleMembers = members
                    .filter { $0.membership == .join && $0.userID != roomProxy.ownUserID && !$0.isServiceMember }
                    .sorted()
                    .map { RoomMemberDetails(withProxy: $0) }
            }
            .store(in: &circleMemberCancellables)

        await roomProxy.updateMembers()
    }

    private func openDirectChat(with member: RoomMemberDetails) async {
        let userID = member.id
        guard userID != clientProxy.userID else { return }

        if let knownRoomID = knownDirectRooms[userID] {
            actionsSubject.send(.selectRoom(roomID: knownRoomID))
            return
        }

        if !pendingDirectRoomUserIDs.insert(userID).inserted {
            return
        }
        defer { pendingDirectRoomUserIDs.remove(userID) }

        switch clientProxy.directRoomForUserID(userID) {
        case .success(.some(let roomID)):
            knownDirectRooms[userID] = roomID
            actionsSubject.send(.selectRoom(roomID: roomID))
        case .success(.none):
            switch await clientProxy.createDirectRoom(with: userID, expectedRoomName: member.name) {
            case .success(let roomID):
                knownDirectRooms[userID] = roomID
                actionsSubject.send(.selectRoom(roomID: roomID))
            case .failure(let error):
                MXLog.error("Unable to create direct room for circle member: \(error)")
                showFailureIndicator()
            }
        case .failure(let error):
            MXLog.error("Unable to find direct room for circle member: \(error)")
            showFailureIndicator()
        }
    }

    // MARK: - Indicators

    private static var failureIndicatorID: String {
        "\(Self.self)-Failure"
    }

    private func showFailureIndicator() {
        userIndicatorController.submitIndicator(UserIndicator(id: Self.failureIndicatorID,
                                                              type: .toast,
                                                              title: L10n.errorUnknown,
                                                              icon: \.close))
    }
}
