//
// Copyright 2025 Element Creations Ltd.
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum SpacesScreenViewModelAction {
    case selectSpace(SpaceRoomListProxyProtocol)
    case selectRoom(roomID: String)
    case showSettings
    case showCreateSpace
}

struct SpacesScreenViewState: BindableState {
    var userProfile: UserProfile

    var topLevelSpaces: [SpaceServiceRoom]
    var selectedSpaceID: String?
    var circleMembers: [RoomMemberDetails]? = nil
}

enum SpacesScreenViewAction {
    case spaceAction(SpaceRoomCell.Action)
    case selectCircle(SpaceServiceRoom)
    case selectCircleMember(RoomMemberDetails)
    case showSettings
    case createSpace
}
