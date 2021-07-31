/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

/// An application specific enum of app features that we are configuring
/// with experiments. These identify parts of the app that can be configured by Nimbus.
///
/// Configuration comes from calling `nimbus.getVariables(featureId)`. The available variables for
/// each feature is documented in `Docs/features.md`.
///
enum NimbusFeatureId: String {
    case nimbusValidation = "nimbus-validation"
    case onboardingDefaultBrowser = "onboarding-default-browser"
    case inactiveTabs = "inactiveTabs"
    case librarySectionExperiment = "library-section-experiment"
    case search = "search"
}

/// A set of common branch ids used in experiments. Branch ids can be application/experiment specific, so
/// _could_ be an `enum`; however, there is a likelihood that they will become less relevant in the future.
enum NimbusExperimentBranch {
    static let a1 = "a1"
    static let a2 = "a2"
    static let control = "control"
    static let treatment = "treatment"
    static let defaultBrowserTreatment = "defaultBrowserTreatment"

    enum InactiveTab {
        static let control = "inactiveTabControl"
        static let treatment = "inactiveTabTreatment"
    }

    enum LibrarySectionABTest {
        static let control = "librarySectionABTestShowLibrary"
        static let variation = "librarySectionABTestShowRecentlySaved"
    }
}
