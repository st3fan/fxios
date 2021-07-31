/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit
import SnapKit
import Storage
import Shared

struct GridTabTrayControllerUX {
    static let CornerRadius = CGFloat(6.0)
    static let TextBoxHeight = CGFloat(32.0)
    static let NavigationToolbarHeight = CGFloat(44)
    static let FaviconSize = CGFloat(20)
    static let Margin = CGFloat(15)
    static let ToolbarButtonOffset = CGFloat(10.0)
    static let CloseButtonSize = CGFloat(32)
    static let CloseButtonMargin = CGFloat(6.0)
    static let CloseButtonEdgeInset = CGFloat(7)
    static let NumberOfColumnsThin = 1
    static let NumberOfColumnsWide = 3
    static let CompactNumberOfColumnsThin = 2
    static let MenuFixedWidth: CGFloat = 320
}

protocol TabTrayDelegate: AnyObject {
    func tabTrayDidDismiss(_ tabTray: GridTabViewController)
    func tabTrayDidAddTab(_ tabTray: GridTabViewController, tab: Tab)
    func tabTrayDidAddBookmark(_ tab: Tab)
    func tabTrayDidAddToReadingList(_ tab: Tab) -> ReadingListItem?
    func tabTrayRequestsPresentationOf(_ viewController: UIViewController)
    func tabTrayOpenRecentlyClosedTab(_ url: URL)
}

class GridTabViewController: UIViewController, TabTrayViewDelegate {
    let tabManager: TabManager
    let profile: Profile
    weak var delegate: TabTrayDelegate?
    var tabDisplayManager: TabDisplayManager!
    var tabCellIdentifer: TabDisplayer.TabCellIdentifer = TabCell.Identifier
    var otherBrowsingModeOffset = CGPoint.zero
    // Backdrop used for displaying greyed background for private tabs
    var webViewContainerBackdrop: UIView!
    var collectionView: UICollectionView!
    var recentlyClosedTabsPanel: RecentlyClosedTabsPanel?
    
    fileprivate lazy var emptyPrivateTabsView: EmptyPrivateTabsView = {
        let emptyView = EmptyPrivateTabsView()
        emptyView.learnMoreButton.addTarget(self, action: #selector(didTapLearnMore), for: .touchUpInside)
        return emptyView
    }()

    fileprivate lazy var tabLayoutDelegate: TabLayoutDelegate = {
        let delegate = TabLayoutDelegate(tabDisplayManager: self.tabDisplayManager, traitCollection: self.traitCollection, scrollView: self.collectionView)
        delegate.tabSelectionDelegate = self
        return delegate
    }()

    var numberOfColumns: Int {
        return tabLayoutDelegate.numberOfColumns
    }
    init(tabManager: TabManager, profile: Profile, tabTrayDelegate: TabTrayDelegate? = nil) {
        self.tabManager = tabManager
        self.profile = profile
        self.delegate = tabTrayDelegate
        super.init(nibName: nil, bundle: nil)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        collectionView.register(TabCell.self, forCellWithReuseIdentifier: TabCell.Identifier)
        collectionView.register(InactiveTabCell.self, forCellWithReuseIdentifier: InactiveTabCell.Identifier)
        tabDisplayManager = TabDisplayManager(collectionView: self.collectionView, tabManager: self.tabManager, tabDisplayer: self, reuseID: TabCell.Identifier, tabDisplayType: .TabGrid, profile: profile)
        collectionView.dataSource = tabDisplayManager
        collectionView.delegate = tabLayoutDelegate

        tabDisplayManager.tabDisplayCompletionDelegate = self
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.view.layoutIfNeeded()
        focusTab()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        // When the app enters split screen mode we refresh the collection view layout to show the proper grid
        collectionView.collectionViewLayout.invalidateLayout()
    }

    deinit {
        tabManager.removeDelegate(self.tabDisplayManager)
        tabManager.removeDelegate(self)
        tabDisplayManager = nil
    }
    
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        guard let flowlayout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout else { return }
        flowlayout.invalidateLayout()
    }
    
    func focusTab() {
        guard let currentTab = tabManager.selectedTab, let index = self.tabDisplayManager.dataStore.index(of: currentTab) else { return }
        let indexPath = IndexPath(item: index, section: 0)
        guard var rect = self.collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
        if index >= self.tabDisplayManager.dataStore.count - 2 {
            DispatchQueue.main.async {
                rect.origin.y += 10
                self.collectionView.scrollRectToVisible(rect, animated: false)
            }
        } else {
            self.collectionView.scrollToItem(at: indexPath, at: [.centeredVertically, .centeredHorizontally] , animated: false)
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc func dynamicFontChanged(_ notification: Notification) {
        guard notification.name == .DynamicFontChanged else { return }
    }

// MARK: View Controller Callbacks
    override func viewDidLoad() {
        super.viewDidLoad()
        tabManager.addDelegate(self)
        view.accessibilityLabel = .TabTrayViewAccessibilityLabel
        
        webViewContainerBackdrop = UIView()
        webViewContainerBackdrop.alpha = 0

        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag

        collectionView.dragInteractionEnabled = true
        collectionView.dragDelegate = tabDisplayManager
        collectionView.dropDelegate = tabDisplayManager

        [webViewContainerBackdrop, collectionView].forEach { view.addSubview($0) }
        makeConstraints()

        view.insertSubview(emptyPrivateTabsView, aboveSubview: collectionView)
        emptyPrivateTabsView.snp.makeConstraints { make in
            make.top.bottom.left.right.equalTo(self.collectionView)
        }

        if let tab = tabManager.selectedTab, tab.isPrivate {
            tabDisplayManager.togglePrivateMode(isOn: true, createTabOnEmptyPrivateMode: false)
        }

        if traitCollection.forceTouchCapability == .available {
            registerForPreviewing(with: self, sourceView: view)
        }

        emptyPrivateTabsView.isHidden = !privateTabsAreEmpty()

        applyTheme()
        notificationSetup()
    }

    private func notificationSetup() {
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActiveNotification), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActiveNotification), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(dynamicFontChanged), name: .DynamicFontChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme), name: .DisplayThemeChanged, object: nil)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // Update the trait collection we reference in our layout delegate
        tabLayoutDelegate.traitCollection = traitCollection
    }

    fileprivate func makeConstraints() {
        webViewContainerBackdrop.snp.makeConstraints { make in
            make.edges.equalTo(self.view)
        }
        
        collectionView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    @objc func didTogglePrivateMode() {
        if tabDisplayManager.isDragging {
            return
        }

        let scaleDownTransform = CGAffineTransform(scaleX: 0.9, y: 0.9)

        let newOffset = CGPoint(x: 0.0, y: collectionView.contentOffset.y)
        if self.otherBrowsingModeOffset.y > 0 {
            collectionView.setContentOffset(self.otherBrowsingModeOffset, animated: false)
        }
        self.otherBrowsingModeOffset = newOffset
        let fromView: UIView
        if !privateTabsAreEmpty(), let snapshot = collectionView.snapshotView(afterScreenUpdates: false) {
            snapshot.frame = collectionView.frame
            view.insertSubview(snapshot, aboveSubview: collectionView)
            fromView = snapshot
        } else {
            fromView = emptyPrivateTabsView
        }

        tabManager.willSwitchTabMode(leavingPBM: tabDisplayManager.isPrivate)
        
        tabDisplayManager.togglePrivateMode(isOn: !tabDisplayManager.isPrivate, createTabOnEmptyPrivateMode: false)

        self.tabDisplayManager.refreshStore()

        // If we are exiting private mode and we have the close private tabs option selected, make sure
        // we clear out all of the private tabs
        let exitingPrivateMode = !tabDisplayManager.isPrivate && tabManager.shouldClearPrivateTabs()

        collectionView.layoutSubviews()

        let toView: UIView
        if !privateTabsAreEmpty(), let newSnapshot = collectionView.snapshotView(afterScreenUpdates: !exitingPrivateMode) {
            emptyPrivateTabsView.isHidden = true
            //when exiting private mode don't screenshot the collectionview (causes the UI to hang)
            newSnapshot.frame = collectionView.frame
            view.insertSubview(newSnapshot, aboveSubview: fromView)
            collectionView.alpha = 0
            toView = newSnapshot
        } else {
            emptyPrivateTabsView.isHidden = false
            toView = emptyPrivateTabsView
        }
        toView.alpha = 0
        toView.transform = scaleDownTransform

        UIView.animate(withDuration: 0.2, delay: 0, options: [], animations: { () -> Void in
            fromView.transform = scaleDownTransform
            fromView.alpha = 0
            toView.transform = .identity
            toView.alpha = 1
        }) { finished in
            if fromView != self.emptyPrivateTabsView {
                fromView.removeFromSuperview()
            }
            if toView != self.emptyPrivateTabsView {
                toView.removeFromSuperview()
            }
            self.collectionView.alpha = 1

            // A final reload to ensure no animations happen while completing the transition.
            self.tabDisplayManager.refreshStore()
        }
    }

    fileprivate func privateTabsAreEmpty() -> Bool {
        return tabDisplayManager.isPrivate && tabManager.privateTabs.isEmpty
    }

    func openNewTab(_ request: URLRequest? = nil, isPrivate: Bool) {
        if tabDisplayManager.isDragging {
            return
        }

        tabManager.selectTab(tabManager.addTab(request, isPrivate: isPrivate))
    }
}

extension GridTabViewController: TabManagerDelegate {
    func tabManager(_ tabManager: TabManager, didSelectedTabChange selected: Tab?, previous: Tab?, isRestoring: Bool) {}
    func tabManager(_ tabManager: TabManager, didAddTab tab: Tab, placeNextToParentTab: Bool, isRestoring: Bool) {}
    func tabManager(_ tabManager: TabManager, didRemoveTab tab: Tab, isRestoring: Bool) {}
    func tabManagerDidAddTabs(_ tabManager: TabManager) {}

    func tabManagerDidRestoreTabs(_ tabManager: TabManager) {
        self.emptyPrivateTabsView.isHidden = !self.privateTabsAreEmpty()
    }

    func tabManagerDidRemoveAllTabs(_ tabManager: TabManager, toast: ButtonToast?) {
        // No need to handle removeAll toast in TabTray.
        // When closing all normal tabs we automatically focus a tab and show the BVC. Which will handle the Toast.
        // We don't show the removeAll toast in PBM
    }
}

extension GridTabViewController: TabDisplayer {

    func focusSelectedTab() {
        self.focusTab()
    }

    func cellFactory(for cell: UICollectionViewCell, using tab: Tab) -> UICollectionViewCell {
        guard let tabCell = cell as? TabCell else { return cell }
        tabCell.animator.delegate = self
        tabCell.delegate = self
        let selected = tab == tabManager.selectedTab
        tabCell.configureWith(tab: tab, is: selected)
        return tabCell
    }
}

extension GridTabViewController {

    @objc func didTapLearnMore() {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if let langID = Locale.preferredLanguages.first {
            let learnMoreRequest = URLRequest(url: "https://support.mozilla.org/1/mobile/\(appVersion ?? "0.0")/iOS/\(langID)/private-browsing-ios".asURL!)
            openNewTab(learnMoreRequest, isPrivate: tabDisplayManager.isPrivate)
        }
    }

    func closeTabsForCurrentTray() {
        let tabs = self.tabDisplayManager.dataStore.compactMap { $0 }
        let maxTabs = 100
        if tabs.count >= maxTabs {
            self.tabManager.removeTabsAndAddNormalTab(tabs)
        } else {
            self.tabManager.removeTabsWithToast(tabs)
        }
        closeTabsTrayHelper()
    }
    
    func closeTabsTrayHelper() {
        if self.tabDisplayManager.isPrivate {
            self.emptyPrivateTabsView.isHidden = !self.privateTabsAreEmpty()
            if !self.emptyPrivateTabsView.isHidden {
                // Fade in the empty private tabs message. This slow fade allows time for the closing tab animations to complete.
                self.emptyPrivateTabsView.alpha = 0
                UIView.animate(withDuration: 0.5, animations: {
                    self.emptyPrivateTabsView.alpha = 1
                }, completion: nil)
            }
        } else if self.tabManager.normalTabs.count == 1, let tab = self.tabManager.normalTabs.first {
            self.tabManager.selectTab(tab)
            self.dismissTabTray()
        }
    }

    func didTogglePrivateMode(_ togglePrivateModeOn: Bool) {
        if togglePrivateModeOn != tabDisplayManager.isPrivate {
            didTogglePrivateMode()
        }
    }

    func dismissTabTray() {
        collectionView.layer.removeAllAnimations()
        collectionView.cellForItem(at: IndexPath(row: 0, section: 0))?.layer.removeAllAnimations()
        _ = self.navigationController?.dismiss(animated: true, completion: nil)
        TelemetryWrapper.recordEvent(category: .action, method: .close, object: .tabTray)
    }

}

// MARK: - App Notifications
extension GridTabViewController {
    @objc func appWillResignActiveNotification() {
        if tabDisplayManager.isPrivate {
            webViewContainerBackdrop.alpha = 1
            view.bringSubviewToFront(webViewContainerBackdrop)
            collectionView.alpha = 0
            emptyPrivateTabsView.alpha = 0
        }
    }

    @objc func appDidBecomeActiveNotification() {
        // Re-show any components that might have been hidden because they were being displayed
        // as part of a private mode tab
        UIView.animate(withDuration: 0.2, animations: {
            self.collectionView.alpha = 1
            self.emptyPrivateTabsView.alpha = 1
        }) { _ in
            self.webViewContainerBackdrop.alpha = 0
            self.view.sendSubviewToBack(self.webViewContainerBackdrop)
        }
    }
}

extension GridTabViewController: TabSelectionDelegate {
    func didSelectTabAtIndex(_ index: Int) {
        if let tab = tabDisplayManager.dataStore.at(index) {
            tabManager.selectTab(tab)
            dismissTabTray()
        }
    }
}

extension GridTabViewController: PresentingModalViewControllerDelegate {
    func dismissPresentedModalViewController(_ modalViewController: UIViewController, animated: Bool) {
        dismiss(animated: animated, completion: { self.collectionView.reloadData() })
    }
}

extension GridTabViewController: UIScrollViewAccessibilityDelegate {
    func accessibilityScrollStatus(for scrollView: UIScrollView) -> String? {
        guard var visibleCells = collectionView.visibleCells as? [TabCell] else { return nil }
        var bounds = collectionView.bounds
        bounds = bounds.offsetBy(dx: collectionView.contentInset.left, dy: collectionView.contentInset.top)
        bounds.size.width -= collectionView.contentInset.left + collectionView.contentInset.right
        bounds.size.height -= collectionView.contentInset.top + collectionView.contentInset.bottom
        // visible cells do sometimes return also not visible cells when attempting to go past the last cell with VoiceOver right-flick gesture; so make sure we have only visible cells (yeah...)
        visibleCells = visibleCells.filter { !$0.frame.intersection(bounds).isEmpty }

        let cells = visibleCells.map { self.collectionView.indexPath(for: $0)! }
        let indexPaths = cells.sorted { (a: IndexPath, b: IndexPath) -> Bool in
            return a.section < b.section || (a.section == b.section && a.row < b.row)
        }

        guard !indexPaths.isEmpty else {
            return .TabTrayNoTabsAccessibilityHint
        }

        let firstTab = indexPaths.first!.row + 1
        let lastTab = indexPaths.last!.row + 1
        let tabCount = collectionView.numberOfItems(inSection: 0)

        if firstTab == lastTab {
            let format: String = .TabTrayVisibleTabRangeAccessibilityHint
            return String(format: format, NSNumber(value: firstTab as Int), NSNumber(value: tabCount as Int))
        } else {
            let format: String = .TabTrayVisiblePartialRangeAccessibilityHint
            return String(format: format, NSNumber(value: firstTab as Int), NSNumber(value: lastTab as Int), NSNumber(value: tabCount as Int))
        }
    }
}

extension GridTabViewController: SwipeAnimatorDelegate {
    func swipeAnimator(_ animator: SwipeAnimator, viewWillExitContainerBounds: UIView) {
        guard let tabCell = animator.animatingView as? TabCell, let indexPath = collectionView.indexPath(for: tabCell) else { return }
        if let tab = tabDisplayManager.dataStore.at(indexPath.item) {
            self.removeByButtonOrSwipe(tab: tab, cell: tabCell)
            UIAccessibility.post(notification: UIAccessibility.Notification.announcement, argument: String.TabTrayClosingTabAccessibilityMessage)
        }
    }

    // Disable swipe delete while drag reordering
    func swipeAnimatorIsAnimateAwayEnabled(_ animator: SwipeAnimator) -> Bool {
        return !tabDisplayManager.isDragging
    }
}

extension GridTabViewController: TabCellDelegate {
    func tabCellDidClose(_ cell: TabCell) {
        if let indexPath = collectionView.indexPath(for: cell), let tab = tabDisplayManager.dataStore.at(indexPath.item) {
            removeByButtonOrSwipe(tab: tab, cell: cell)
        }
    }
}

extension GridTabViewController: TabPeekDelegate {

    func tabPeekDidAddBookmark(_ tab: Tab) {
        delegate?.tabTrayDidAddBookmark(tab)
    }

    func tabPeekDidAddToReadingList(_ tab: Tab) -> ReadingListItem? {
        return delegate?.tabTrayDidAddToReadingList(tab)
    }

    func tabPeekDidCloseTab(_ tab: Tab) {
        if let index = tabDisplayManager.dataStore.index(of: tab),
            let cell = self.collectionView?.cellForItem(at: IndexPath(item: index, section: 0)) as? TabCell {
            cell.close()
        }
    }

    func tabPeekRequestsPresentationOf(_ viewController: UIViewController) {
        delegate?.tabTrayRequestsPresentationOf(viewController)
    }
}

extension GridTabViewController: UIViewControllerPreviewingDelegate {

    func previewingContext(_ previewingContext: UIViewControllerPreviewing, viewControllerForLocation location: CGPoint) -> UIViewController? {

        guard let collectionView = collectionView else { return nil }
        let convertedLocation = self.view.convert(location, to: collectionView)

        guard let indexPath = collectionView.indexPathForItem(at: convertedLocation),
            let cell = collectionView.cellForItem(at: indexPath) else { return nil }

        guard let tab = tabDisplayManager.dataStore.at(indexPath.row) else {
            return nil
        }
        let tabVC = TabPeekViewController(tab: tab, delegate: self)
        if let browserProfile = profile as? BrowserProfile {
            tabVC.setState(withProfile: browserProfile, clientPickerDelegate: self)
        }
        previewingContext.sourceRect = self.view.convert(cell.frame, from: collectionView)

        return tabVC
    }

    func previewingContext(_ previewingContext: UIViewControllerPreviewing, commit viewControllerToCommit: UIViewController) {
        guard let tpvc = viewControllerToCommit as? TabPeekViewController else { return }
        tabManager.selectTab(tpvc.tab)
        navigationController?.popViewController(animated: true)
        delegate?.tabTrayDidDismiss(self)
    }
}

extension GridTabViewController: TabDisplayCompletionDelegate, RecentlyClosedPanelDelegate {
    // RecentlyClosedPanelDelegate
    func openRecentlyClosedSiteInSameTab(_ url: URL) {
        TelemetryWrapper.recordEvent(category: .action, method: .tap, object: .inactiveTabTray, value: .openRecentlyClosedTab, extras: nil)
        delegate?.tabTrayOpenRecentlyClosedTab(url)
        dismissTabTray()
    }
    
    func openRecentlyClosedSiteInNewTab(_ url: URL, isPrivate: Bool) {
        TelemetryWrapper.recordEvent(category: .action, method: .tap, object: .inactiveTabTray, value: .openRecentlyClosedTab, extras: nil)
        openNewTab(URLRequest(url: url), isPrivate: isPrivate)
        dismissTabTray()
    }
    
    // TabDisplayCompletionDelegate
    func displayRecentlyClosedTabs() {
        recentlyClosedTabsPanel = RecentlyClosedTabsPanel(profile: profile)
        recentlyClosedTabsPanel!.title = Strings.RecentlyClosedTabsButtonTitle
        recentlyClosedTabsPanel!.recentlyClosedTabsDelegate = self
        navigationController?.pushViewController(recentlyClosedTabsPanel!, animated: true)
    }
    
    func completedAnimation(for type: TabAnimationType) {
        emptyPrivateTabsView.isHidden = !privateTabsAreEmpty()

        switch type {
        case .addTab:
            dismissTabTray()
        case .removedLastTab:
            // when removing the last tab (only in normal mode) we will automatically open a new tab.
            // When that happens focus it by dismissing the tab tray
            if !tabDisplayManager.isPrivate {
                self.dismissTabTray()
            }
        case .removedNonLastTab, .updateTab, .moveTab:
            break
        }
    }
}

extension GridTabViewController {
    func removeByButtonOrSwipe(tab: Tab, cell: TabCell) {
        tabDisplayManager.tabDisplayCompletionDelegate = self
        tabDisplayManager.closeActionPerformed(forCell: cell)
    }
}

// MARK: - Toolbar Actions
extension GridTabViewController {
    func performToolbarAction(_ action: TabTrayViewAction, sender: UIBarButtonItem) {
        switch action {
        case .addTab:
            didTapToolbarAddTab()
        case .deleteTab:
            didTapToolbarDelete(sender)
        }
    }

    func didTapToolbarAddTab() {
        if tabDisplayManager.isDragging {
            return
        }
        openNewTab(isPrivate: tabDisplayManager.isPrivate)
    }

    func didTapToolbarDelete(_ sender: UIBarButtonItem) {
        if tabDisplayManager.isDragging {
            return
        }

        let controller = AlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        controller.addAction(UIAlertAction(title: Strings.AppMenuCloseAllTabsTitleString, style: .default, handler: { _ in self.closeTabsForCurrentTray() }), accessibilityIdentifier: "TabTrayController.deleteButton.closeAll")
        controller.addAction(UIAlertAction(title: .TabTrayCloseAllTabsPromptCancel, style: .cancel, handler: nil), accessibilityIdentifier: "TabTrayController.deleteButton.cancel")
        controller.popoverPresentationController?.barButtonItem = sender
        present(controller, animated: true, completion: nil)
    }
}

fileprivate class TabLayoutDelegate: NSObject, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {
    weak var tabSelectionDelegate: TabSelectionDelegate?
    var searchHeightConstraint: Constraint?
    let scrollView: UIScrollView
    var lastYOffset: CGFloat = 0
    var tabDisplayManager: TabDisplayManager
    
    enum ScrollDirection {
        case up
        case down
    }

    fileprivate var scrollDirection: ScrollDirection = .down
    fileprivate var traitCollection: UITraitCollection
    fileprivate var numberOfColumns: Int {
        // iPhone 4-6+ portrait
        if traitCollection.horizontalSizeClass == .compact && traitCollection.verticalSizeClass == .regular {
            return GridTabTrayControllerUX.CompactNumberOfColumnsThin
        } else {
            return GridTabTrayControllerUX.NumberOfColumnsWide
        }
    }

    init(tabDisplayManager: TabDisplayManager, traitCollection: UITraitCollection, scrollView: UIScrollView) {
        self.tabDisplayManager = tabDisplayManager
        self.scrollView = scrollView
        self.traitCollection = traitCollection
        super.init()
    }

    fileprivate func cellHeightForCurrentDevice() -> CGFloat {
        let shortHeight = GridTabTrayControllerUX.TextBoxHeight * 6

        if self.traitCollection.verticalSizeClass == .compact {
            return shortHeight
        } else if self.traitCollection.horizontalSizeClass == .compact {
            return shortHeight
        } else {
            return GridTabTrayControllerUX.TextBoxHeight * 8
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    @objc func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumInteritemSpacingForSectionAt section: Int) -> CGFloat {
        return GridTabTrayControllerUX.Margin
    }

    @objc func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let cellWidth = floor((collectionView.bounds.width - GridTabTrayControllerUX.Margin * CGFloat(numberOfColumns + 1)) / CGFloat(numberOfColumns))
        switch TabDisplaySection(rawValue: indexPath.section) {
        case .regularTabs, .none:
            return CGSize(width: cellWidth, height: self.cellHeightForCurrentDevice())
        case .inactiveTabs:
            if tabDisplayManager.isPrivate { return CGSize(width: 0, height: 0) }
            let minInactiveCellHeight = Int(InactiveTabCellUX.headerAndRowHeight)
            // Default height for footer and recently closed cell
            let headerFooterCellCombinedHeight = minInactiveCellHeight*3
            var totalHeight = headerFooterCellCombinedHeight + minInactiveCellHeight
            let width = collectionView.frame.size.width - 30

            if let inactiveTabs = tabDisplayManager.inactiveViewModel?.inactiveTabs, inactiveTabs.count > 0 {
                // Calculate height based on number of tabs in the inactive tab section section
                totalHeight = minInactiveCellHeight*inactiveTabs.count + headerFooterCellCombinedHeight
            }

            totalHeight = tabDisplayManager.isInactiveViewExpanded ? totalHeight : minInactiveCellHeight
            
            if UIDevice.current.userInterfaceIdiom == .pad {
                return CGSize(width: Int(collectionView.frame.size.width/2), height: totalHeight)
            } else {
                return CGSize(width: width >= 0 ? Int(width) : 0, height: totalHeight)
            }
        }
    }

    @objc func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
        return UIEdgeInsets(equalInset: GridTabTrayControllerUX.Margin)
    }

    @objc func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat {
        return GridTabTrayControllerUX.Margin
    }

    @objc func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        tabSelectionDelegate?.didSelectTabAtIndex(indexPath.row)
    }
}

extension GridTabViewController: DevicePickerViewControllerDelegate {
    func devicePickerViewController(_ devicePickerViewController: DevicePickerViewController, didPickDevices devices: [RemoteDevice]) {
        if let item = devicePickerViewController.shareItem {
            _ = self.profile.sendItem(item, toDevices: devices)
        }
        devicePickerViewController.dismiss(animated: true, completion: nil)
    }

    func devicePickerViewControllerDidCancel(_ devicePickerViewController: DevicePickerViewController) {
        devicePickerViewController.dismiss(animated: true, completion: nil)
    }
}

extension GridTabViewController: UIAdaptivePresentationControllerDelegate, UIPopoverPresentationControllerDelegate {
    // Returning None here makes sure that the Popover is actually presented as a Popover and
    // not as a full-screen modal, which is the default on compact device classes.
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        return .none
    }
}

protocol TabCellDelegate: AnyObject {
    func tabCellDidClose(_ cell: TabCell)
}

class TabCell: UICollectionViewCell {
    enum Style {
        case light
        case dark
    }

    static let Identifier = "TabCellIdentifier"
    static let BorderWidth: CGFloat = 3

    let backgroundHolder: UIView = {
        let view = UIView()
        view.layer.cornerRadius = GridTabTrayControllerUX.CornerRadius
        view.clipsToBounds = true
        view.backgroundColor = UIColor.theme.tabTray.cellBackground
        return view
    }()

    let screenshotView: UIImageViewAligned = {
        let view = UIImageViewAligned()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        view.alignLeft = true
        view.alignTop = true
        view.backgroundColor = UIColor.theme.tabTray.screenshotBackground
        return view
    }()

    let titleText: UILabel = {
        let label = UILabel()
        label.isUserInteractionEnabled = false
        label.numberOfLines = 1
        label.font = DynamicFontHelper.defaultHelper.DefaultSmallFontBold
        label.textColor = UIColor.theme.tabTray.tabTitleText
        return label
    }()

    let favicon: UIImageView = {
        let favicon = UIImageView()
        favicon.backgroundColor = UIColor.clear
        favicon.layer.cornerRadius = 2.0
        favicon.layer.masksToBounds = true
        return favicon
    }()

    let closeButton: UIButton = {
        let button = UIButton()
        button.setImage(UIImage.templateImageNamed("tab_close"), for: [])
        button.imageView?.contentMode = .scaleAspectFit
        button.contentMode = .center
        button.tintColor = UIColor.theme.tabTray.cellCloseButton
        button.imageEdgeInsets = UIEdgeInsets(equalInset: GridTabTrayControllerUX.CloseButtonEdgeInset)
        return button
    }()

    var title = UIVisualEffectView(effect: UIBlurEffect(style: UIColor.theme.tabTray.tabTitleBlur))
    var animator: SwipeAnimator!

    weak var delegate: TabCellDelegate?

    // Changes depending on whether we're full-screen or not.
    var margin = CGFloat(0)

    override init(frame: CGRect) {
        super.init(frame: frame)

        self.animator = SwipeAnimator(animatingView: self)
        self.closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        contentView.addSubview(backgroundHolder)
        backgroundHolder.addSubview(self.screenshotView)

        self.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: .TabTrayCloseAccessibilityCustomAction, target: self.animator, selector: #selector(SwipeAnimator.closeWithoutGesture))
        ]

        backgroundHolder.addSubview(title)
        title.contentView.addSubview(self.closeButton)
        title.contentView.addSubview(self.titleText)
        title.contentView.addSubview(self.favicon)

        title.snp.makeConstraints { (make) in
            make.top.left.right.equalTo(backgroundHolder)
            make.height.equalTo(GridTabTrayControllerUX.TextBoxHeight)
        }

        favicon.snp.makeConstraints { make in
            make.leading.equalTo(title.contentView).offset(6)
            make.top.equalTo((GridTabTrayControllerUX.TextBoxHeight - GridTabTrayControllerUX.FaviconSize) / 2)
            make.size.equalTo(GridTabTrayControllerUX.FaviconSize)
        }

        titleText.snp.makeConstraints { (make) in
            make.leading.equalTo(favicon.snp.trailing).offset(6)
            make.trailing.equalTo(closeButton.snp.leading).offset(-6)
            make.centerY.equalTo(title.contentView)
        }

        closeButton.snp.makeConstraints { make in
            make.size.equalTo(GridTabTrayControllerUX.CloseButtonSize)
            make.centerY.trailing.equalTo(title.contentView)
        }
    }

    func setTabSelected(_ isPrivate: Bool) {
        // This creates a border around a tabcell. Using the shadow craetes a border _outside_ of the tab frame.
        layer.shadowColor = (isPrivate ? UIColor.theme.tabTray.privateModePurple : UIConstants.SystemBlueColor).cgColor
        layer.shadowOpacity = 1
        layer.shadowRadius = 0 // A 0 radius creates a solid border instead of a gradient blur
        layer.masksToBounds = false
        // create a frame that is "BorderWidth" size bigger than the cell
        layer.shadowOffset = CGSize(width: -TabCell.BorderWidth, height: -TabCell.BorderWidth)
        let shadowPath = CGRect(width: layer.frame.width + (TabCell.BorderWidth * 2), height: layer.frame.height + (TabCell.BorderWidth * 2))
        layer.shadowPath = UIBezierPath(roundedRect: shadowPath, cornerRadius: GridTabTrayControllerUX.CornerRadius+TabCell.BorderWidth).cgPath
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        backgroundHolder.frame = CGRect(x: margin, y: margin, width: frame.width, height: frame.height)
        screenshotView.frame = CGRect(size: backgroundHolder.frame.size)

        let shadowPath = CGRect(width: layer.frame.width + (TabCell.BorderWidth * 2), height: layer.frame.height + (TabCell.BorderWidth * 2))
        layer.shadowPath = UIBezierPath(roundedRect: shadowPath, cornerRadius: GridTabTrayControllerUX.CornerRadius+TabCell.BorderWidth).cgPath
    }

    func configureWith(tab: Tab, is selected: Bool) {
        titleText.text = tab.displayTitle

        if selected {
            accessibilityLabel = tab.displayTitle + ". " + String.TabTrayCurrentlySelectedTabAccessibilityLabel
        } else if !tab.displayTitle.isEmpty {
            accessibilityLabel = tab.displayTitle
        } else if let url = tab.url, let about = InternalURL(url)?.aboutComponent {
            accessibilityLabel = about
        } else {
            accessibilityLabel = ""
        }

        isAccessibilityElement = true
        accessibilityHint = .TabTraySwipeToCloseAccessibilityHint

        if let favIcon = tab.displayFavicon, let url = URL(string: favIcon.url) {
            favicon.sd_setImage(with: url, placeholderImage: UIImage(named: "defaultFavicon"), options: [], completed: nil)
        } else {
            favicon.image = UIImage(named: "defaultFavicon")
            favicon.tintColor = UIColor.theme.tabTray.faviconTint
        }
        if selected {
            setTabSelected(tab.isPrivate)
        } else {
            layer.shadowOffset = .zero
            layer.shadowPath = nil
            layer.shadowOpacity = 0
        }
        screenshotView.image = tab.screenshot
    }

    override func prepareForReuse() {
        // Reset any close animations.
        super.prepareForReuse()
        backgroundHolder.transform = .identity
        backgroundHolder.alpha = 1
        self.titleText.font = DynamicFontHelper.defaultHelper.DefaultSmallFontBold
        layer.shadowOffset = .zero
        layer.shadowPath = nil
        layer.shadowOpacity = 0
        isHidden = false
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        var right: Bool
        switch direction {
        case .left:
            right = false
        case .right:
            right = true
        default:
            return false
        }
        animator.close(right: right)
        return true
    }

    @objc func close() {
        delegate?.tabCellDidClose(self)
    }
}

extension GridTabViewController: Themeable {

    @objc func applyTheme() {
        webViewContainerBackdrop.backgroundColor = UIColor.Photon.Ink90
        collectionView.backgroundColor = UIColor.theme.tabTray.background
        let indexPath = IndexPath(row: 0, section: 1)
        if let cell = collectionView.cellForItem(at: indexPath) as? InactiveTabCell {
            cell.applyTheme()
        }
    }
}
