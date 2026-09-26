//
// Copyright 2025 Element Creations Ltd.
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

private let silentBrandBlue = Color(red: 0.082, green: 0.333, blue: 0.878)
private let silentBrandBlueSoft = Color(red: 0.91, green: 0.95, blue: 1.0)

struct SpacesScreen: View {
    @Bindable var context: SpacesScreenViewModel.Context

    private var selectedSpace: SpaceServiceRoom? {
        context.viewState.topLevelSpaces.first { $0.id == context.viewState.selectedSpaceID } ?? context.viewState.topLevelSpaces.first
    }

    var body: some View {
        mainContent
            .navigationTitle("Circles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .toolbarRole(Compound.supportsGlass ? .editor : .automatic)
            .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
            .toolbarBackground(silentBrandBlue, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .tint(.white)
    }

    @ViewBuilder
    private var mainContent: some View {
        if context.viewState.topLevelSpaces.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    circlesSelector
                    header
                    contactsHeader
                    contacts
                }
            }
        }
    }

    private var emptyState: some View {
        FullscreenDialog(horizontalPadding: 24) {
            TitleAndIcon(title: "No circles yet",
                         icon: \.spaceSolid,
                         iconStyle: .defaultSolid)
        } bottomContent: {
            Button("Create circle") {
                context.send(viewAction: .createSpace)
            }
            .buttonStyle(.compound(.primary))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                if let selectedSpace {
                    RoomAvatarImage(avatar: selectedSpace.avatar,
                                    avatarSize: .room(on: .spaceHeader),
                                    mediaProvider: context.mediaProvider)
                        .accessibilityHidden(true)
                } else {
                    BigIcon(icon: \.spaceSolid)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedSpace?.name ?? "Circles")
                        .font(.compound.headingMDBold)
                        .foregroundStyle(.compound.textPrimary)
                        .lineLimit(1)

                    Text(selectedSpace.map { "\($0.joinedMembersCount) contacts" } ?? "\(context.viewState.topLevelSpaces.count) circles")
                        .font(.compound.bodyMD)
                        .foregroundStyle(.compound.textSecondary)
                }

                Spacer()

                Button {
                    if let selectedSpace {
                        context.send(viewAction: .spaceAction(.select(selectedSpace)))
                    }
                } label: {
                    CompoundIcon(\.edit, size: .medium, relativeTo: .compound.bodyMD)
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(silentBrandBlue, in: Circle())
                }
                .accessibilityLabel(L10n.commonSettings)
                .disabled(selectedSpace == nil)
            }

            Text("Choose a circle to see its contacts.")
                .font(.compound.bodyMD)
                .foregroundStyle(.compound.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .background {
            LinearGradient(colors: [silentBrandBlueSoft,
                                    Color(red: 0.96, green: 0.92, blue: 1.0),
                                    Color.compound.bgCanvasDefault],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
        }
    }

    private var circlesSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                Button {
                    context.send(viewAction: .createSpace)
                } label: {
                    VStack(spacing: 5) {
                        CompoundIcon(\.plus)
                            .foregroundStyle(silentBrandBlue)
                            .frame(width: 46, height: 46)
                            .background(Color(red: 0.91, green: 0.95, blue: 1.0), in: Circle())
                        Text("New")
                            .font(.compound.bodyXSSemibold)
                            .foregroundStyle(.compound.textSecondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)

                ForEach(context.viewState.topLevelSpaces, id: \.id) { spaceServiceRoom in
                    let isSelected = spaceServiceRoom.id == selectedSpace?.id
                    Button {
                        context.send(viewAction: .selectCircle(spaceServiceRoom))
                    } label: {
                        VStack(spacing: 5) {
                            RoomAvatarImage(avatar: spaceServiceRoom.avatar,
                                            avatarSize: .user(on: .roomMembersList),
                                            mediaProvider: context.mediaProvider)
                                .frame(width: 46, height: 46)
                                .overlay {
                                    Circle()
                                        .stroke(isSelected ? silentBrandBlue : Color.compound.borderDisabled,
                                                lineWidth: isSelected ? 2 : 1)
                                }

                            Text(spaceServiceRoom.name)
                                .font(.compound.bodyXSSemibold)
                                .foregroundStyle(isSelected ? silentBrandBlue : Color.compound.textSecondary)
                                .lineLimit(1)
                        }
                        .frame(width: 60)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 10)
        .background(Color.compound.bgCanvasDefault)
    }

    private var contactsHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Contacts")
                .font(.compound.headingSMSemibold)
                .foregroundStyle(silentBrandBlue)

            HStack(spacing: 8) {
                CompoundIcon(\.search, size: .small, relativeTo: .compound.bodyMD)
                    .foregroundStyle(.compound.iconSecondary)
                TextField("Search contacts...", text: $context.searchQuery)
                    .font(.compound.bodyMD)
                    .foregroundStyle(.compound.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Color.compound.bgCanvasDefault, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.compound.borderDisabled)
            }

            Text("Show: All")
                .font(.compound.bodySM)
                .foregroundStyle(.compound.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var contacts: some View {
        if let circleMembers = context.viewState.visibleCircleMembers {
            if circleMembers.isEmpty {
                circleMessage(context.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No contacts found" : "No matching contacts")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(circleMembers.enumerated()), id: \.element.id) { index, member in
                        circleMemberRow(member: member,
                                        isLast: index == circleMembers.count - 1)
                    }
                }
            }
        } else {
            circleMessage("Loading contacts...")
        }
    }

    private func circleMemberRow(member: RoomMemberDetails, isLast: Bool) -> some View {
        Button {
            context.send(viewAction: .selectCircleMember(member))
        } label: {
            HStack(spacing: 12) {
                LoadableAvatarImage(url: member.avatarURL,
                                    name: member.name,
                                    contentID: member.id,
                                    avatarSize: .user(on: .roomMembersList),
                                    mediaProvider: context.mediaProvider)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(member.name ?? member.id)
                        .font(.compound.bodyLGSemibold)
                        .foregroundStyle(.compound.textPrimary)
                        .lineLimit(1)

                    Text(member.id)
                        .font(.compound.bodySM)
                        .foregroundStyle(.compound.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                CompoundIcon(\.chat, size: .small, relativeTo: .compound.bodyMD)
                    .foregroundStyle(silentBrandBlue)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.compound.bgCanvasDefault)
            .overlay(alignment: .bottom) {
                if !isLast {
                    Rectangle()
                        .fill(Color.compound.borderDisabled)
                        .frame(height: 1 / UIScreen.main.scale)
                        .padding(.leading, 60)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func circleMessage(_ message: String) -> some View {
        Text(message)
            .font(.compound.bodyMD)
            .foregroundStyle(.compound.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
            .background(Color.compound.bgCanvasDefault)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Use the title placement on iOS 26 to match the chats tab and fix a weird animation.
        ToolbarItem(placement: Compound.supportsGlass ? .title : .navigationBarLeading) {
            Button {
                context.send(viewAction: .showSettings)
            } label: {
                AvatarSettingsButtonLabel(userProfile: context.viewState.userProfile,
                                          mediaProvider: context.mediaProvider)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.commonSettings)
            .accessibilityIdentifier(A11yIdentifiers.homeScreen.userAvatar)
        }
        .backportSharedBackgroundVisibility(.hidden)

        // No need to hide the title on iOS 26, as we use the .title placement for the settings
        // button to workaround a weird liquid glass transition.
        if #unavailable(iOS 26) {
            ToolbarItem(placement: .principal) {
                // Hides the navigationTitle (which is set for the navigation stack label).
                Text("").accessibilityHidden(true)
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                context.send(viewAction: .createSpace)
            } label: {
                CompoundIcon(\.plus)
                    .accessibilityHidden(true)
            }
            .accessibilityLabel("Create circle")
        }
    }
}

// MARK: - Previews

struct SpacesScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = makeViewModel()
    static let emptyViewModel = makeViewModel(isEmpty: true)

    static var previews: some View {
        ElementNavigationStack {
            SpacesScreen(context: viewModel.context)
        }

        ElementNavigationStack {
            SpacesScreen(context: emptyViewModel.context)
        }
        .previewDisplayName("Empty")
    }

    static func makeViewModel(isEmpty: Bool = false) -> SpacesScreenViewModel {
        let clientProxy = ClientProxyMock(.init())
        clientProxy.spaceService = SpaceServiceProxyMock(.init(topLevelSpaces: isEmpty ? [] : .mockJoinedSpaces))

        return SpacesScreenViewModel(userSession: UserSessionMock(.init(clientProxy: clientProxy)),
                                     selectedSpacePublisher: .init(nil),
                                     userIndicatorController: UserIndicatorControllerMock())
    }
}
