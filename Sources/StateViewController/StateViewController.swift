#if canImport(UIKit)

import UIKit

/// A container view controller that manages the appearance of one or more child view controller for any given state.
///
/// ## Overview
/// This class is designed to make stateful view controller programming easier. Typically in iOS development,
/// views representing multiple states are managed in one single view controller, leading to large view controller
/// classes that quickly become hard to work with and overlook at a glance. For instance, a view controller may
/// display an activity indicator while a network call is performed, leaving the view controller to have to directly
/// manipulate view hierarhy for each state. Furthermore, the state of a view controller tends to be represented by
/// conditions that are hard to synchronize, easily becoming a source of bugs and unexpected behavior.
/// With `StateViewController` each state can be represented by one or more view controllers.
/// This allows you to composite view controllers in self-contained classes resulting in smaller view
/// controllers and better ability modularize your view controller code, with clear separation between states.
///
/// ## Subclassing notes
///
/// You must subclass `StateViewController` and define a state for the view controller you are creating.
/// ```
/// enum MyViewControllerState {
///     case loading
///     case ready
/// }
/// ```
/// **Note:** Your state must conform to `Equatable` in order for `StateViewController` to distinguish between states.
///
/// Override `loadAppearanceState()` to determine which state is being represented each time this view controller
/// is appearing on screen. In this method is appropriate to query your model layer to determine whether data needed
/// for a certain state is available or not.
///
/// ```
/// override func loadAppearanceState() -> MyViewControllerState {
///     if model.isDataAvailable {
///         return .ready
///     } else {
///         return .loading
///     }
/// }
/// ```
///
/// To determine which content view controllers represent a particular state, you must override
/// `children(for:)`.
///
/// ```
/// override func children(for state: MyViewControllerState) -> [UIViewController] {
///     switch state {
///     case .loading:
///         return [ActivityIndicatorViewController()]
///     case .empty:
///         return [myChild]
///     }
/// }
/// ```
///
/// Callback methods are overridable, notifying you when a state transition is being performed, and what child
/// view controllers are being presented as a result of a state transition.
///
/// Using `willTransition(to:animated:)` you should prepare view controller representing the state being transition to
/// with the appropriate data.
///
/// ```
/// override func willTransition(to state: MyViewControllerState, animated: Bool) {
///     switch state {
///     case .ready:
///         myChild.content = myLoadedContent
///     case .loading:
///         break
///     }
/// }
/// ```
/// Overriding `didTransition(to:animated:)` is an appropriate place to invoke methods that eventually results in
/// a state transition being requested using `setNeedsTransition(to:animated:)`, as it ensures that any previous state
/// transitions has been fully completed.
///
/// ```
/// override func didTransition(from previousState: MyViewControllerState?, animated: Bool) {
///     switch state {
///     case .ready:
///         break
///     case .loading:
///         model.loadData { result in
///             self.myLoadedContent = result
///             self.setNeedsTransition(to: .ready, animated: true)
///         }
///     }
/// }
/// ```
///
/// You may also override `loadChildContainerView()` to provide a custom container view for your
/// content view controllers, allowing you to manipulate the view hierarchy above and below the content view
/// controller container view.
///
/// ## Animating state transitions
/// By default, no animations are performed between states. To enable animations, you have three options:
///
/// - Set `defaultStateTransitioningCoordinator`
/// - Override `stateTransitionCoordinator(for:)` in your `StateViewController` subclasses
/// - Conform view controllers contained in `StateViewController` to `StateViewControllerTransitioning`.
open class StateViewController<State>: UIViewController {

    /// Current state storage
    fileprivate var stateInternal: State?

    /// A state currently being transitioned from.
    /// - Note: This property is an optional of an optional, as the previous state may be `nil`.
    fileprivate var transitioningFromState: State??

    /// Indicates whether the state view controller is in an appearance transition, between `viewWillAppear` and
    /// `viewDidAppear`, **or** between `viewWillDisappear` and `viewDidDisappear`.
    fileprivate var isInAppearanceTransition = false

    /// Indicates whether the state view controller is applying an appearance state, as part of its appearance cycle
    fileprivate var isApplyingAppearanceState = false

    /// Stores the next needed state to be transitioned to immediately after a current state transition is finished
    fileprivate var pendingState: (state: State, animated: Bool)?

    /// Set of child view controllers being added as part of a state transition
    fileprivate var viewControllersBeingAdded: Set<UIViewController> = []

    /// Set of child view controllers being removed as part of a state transition
    fileprivate var viewControllersBeingRemoved: Set<UIViewController> = []

    /// :nodoc:
    override public final var shouldAutomaticallyForwardAppearanceMethods: Bool {
        return false // We completely manage forwarding of appearance methods ourselves.
    }

    // MARK: - View lifecycle

    /// :nodoc:
    override open func viewDidLoad() {
        super.viewDidLoad()

        childContainerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        childContainerView.frame = view.bounds
        view.addSubview(childContainerView)
    }

    /// :nodoc:
    override open func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // When `viewWillAppear(animated:)` is called we do not yet connsider ourselves in an appearance transition
        // internally because first we have to assert whether we are changing to an appearannce state.
        isApplyingAppearanceState = false
        isInAppearanceTransition = false

        // Load the appearance state once
        let appearanceState = loadAppearanceState()

        if isMovingToParent {
            setNeedsStateTransition(to: appearanceState, animated: animated)
        } else {
            isApplyingAppearanceState = beginStateTransition(to: appearanceState, animated: animated)
        }

        // Prematurely remove view controllers that are being removed.
        // As we're not yet setting the `isInAppearanceTransition` to `true`, the appearance methods
        // for each child view controller below will be forwarded correctly.
        for child in viewControllersBeingRemoved {
            removeChild(child, animated: false)
        }

        // Note that we're in an appearance transition
        isInAppearanceTransition = true

        // Forward begin appearance transitions to child view controllers.
        forwardBeginApperanceTransition(isAppearing: true, animated: animated)
    }

    /// :nodoc:
    override open func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // Note that we're no longer in an appearance transition
        isInAppearanceTransition = false

        // Forward end appearance transitions to chidl view controllers
        forwardEndAppearanceTransition(didAppear: true, animated: animated)

        // If we're applying the appearance state, finish up by making sure
        // `didMove(to:)` is called on child view controllers.
        if isApplyingAppearanceState {
            for child in viewControllersBeingAdded {
                didAddChild(child, animated: animated)
            }
        }

        // End state transition if needed. Child view controllers may still be in a transition.
        endStateTransitionIfNeeded(animated: animated)
    }

    /// :nodoc:
    override open func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        isInAppearanceTransition = false

        // If we're being dismissed we might as well clear the pending state.
        pendingState = nil

        /// If there are view controllers being added as part of a current state transition, we should
        // add them immediately.
        for child in viewControllersBeingAdded {
            didAddChild(child, animated: animated)
        }

        // Note that we're in an appearance transition
        isInAppearanceTransition = true

        // Forward begin appearance methods
        forwardBeginApperanceTransition(isAppearing: false, animated: animated)
    }

    /// :nodoc:
    override open func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        // Note that we're no longer in an apperance transition
        isInAppearanceTransition = false

        // Prematurely remove all view controllers begin removed
        for child in viewControllersBeingRemoved {
            removeChild(child, animated: animated)
        }

        // Forward end appearance transitions. Will only affect child view controllers not currently
        // in a state transition.
        forwardEndAppearanceTransition(didAppear: false, animated: animated)

        // End state transition if needed.
        endStateTransitionIfNeeded(animated: animated)
    }

    // MARK: - Container view controller forwarding

    #if os(iOS)
    override open var childForStatusBarStyle: UIViewController? {
        children.last
    }

    override open var childForStatusBarHidden: UIViewController? {
        children.last
    }

    @available(iOS 11, *)
    override open var childForScreenEdgesDeferringSystemGestures: UIViewController? {
        children.last
    }

    @available(iOS 11, *)
    override open var childForHomeIndicatorAutoHidden: UIViewController? {
        children.last
    }
    #endif

    // MARK: - State transitioning

    /// Indicates whether the view controller currently is transitioning between states.
    public var isTransitioningBetweenStates: Bool {
        return transitioningFromState != nil
    }

    /// Indicates the current state, or invokes `loadAppearanceState()` is a current state transition has not
    /// yet began.
    public var currentState: State {
        return stateInternal ?? loadAppearanceState()
    }

    /// Indicates whether the state of this view controller has been determined.
    /// In effect, this means that if this value is `true`, you can access `currentState` inside
    // `loadAppearanceState()` without resulting in infinite recursion.
    public var hasDeterminedState: Bool {
        return stateInternal != nil
    }

    /// Loads a state that should represent this view controller immediately as this view controller
    /// is being presented on screen, and returns it.
    ///
    /// - Warning: As `currentState` may invoke use this method you cannot access `currentState` inside this
    /// method without first asserting that `hasDeterminedState` is `true`.
    ///
    /// - Returns: A state
    // swiftlint:disable unavailable_function
    open func loadAppearanceState() -> State {
        fatalError(
            "\(String(describing: self)) does not implement loadAppearanceState(), which is required. " +
            "A StateViewController must immediately be able to resolve its state before entering an " +
            "appearance transition."
        )
    }
    // swiftlint:enable unavailable_function

    /// Notifies the state view controller that a new state is needed.
    /// As soon as the state view controller is ready to change state, a state transition will begin.
    ///
    /// - Note: Multiple calls to this method will result in the last state provided being transitioned to.
    ///
    /// - Parameters:
    ///   - state: State to transition to.
    ///   - animated: Whether to animate the state transition.
    public func setNeedsStateTransition(to state: State, animated: Bool) {

        guard beginStateTransition(to: state, animated: animated) else {
            return
        }

        guard animated else {
            for viewController in viewControllersBeingAdded {
                didAddChild(viewController, animated: animated)
            }

            for viewController in viewControllersBeingRemoved {
                removeChild(viewController, animated: animated)
            }
            return
        }

        performStateTransition(animated: animated)
    }

    // MARK: - Content view controllers

    /// Returns an array of content view controllers representing a state.
    /// The order of the view controllers matter – first in array will be placed first in the container views
    /// view hierarchy.
    ///
    /// - Parameter state: State being represented
    /// - Returns: An array of view controllers
    open func children(for state: State) -> [UIViewController] {
        return []
    }

    /// :nodoc:
    @available(*, unavailable, renamed: "children")
    public func contentViewControllers(for state: State) -> [UIViewController] {
        fatalError("Unavailable")
    }

    /// Internal storage of `childContainerView`
    private var _childContainerView: UIView?

    /// Container view placed directly in the `StateViewController`s view.
    /// Content view controllers are placed inside this view, edge to edge.
    /// - Important: You should not directly manipulate the view hierarchy of this view
    public var childContainerView: UIView {
        guard let existing = _childContainerView else {
            let new = loadChildContainerView()
            new.preservesSuperviewLayoutMargins = true
            _childContainerView = new
            return new
        }

        return existing
    }

    /// :nodoc:
    @available(*, unavailable, renamed: "childContainerView")
    public var contentViewControllerContainerView: UIView {
        fatalError("Unavailable")
    }

    /// Creates the `childContainerView` used as a container view for content view controllers.
    //
    /// - Note: This method is only called once.
    ///
    /// - Returns: A `UIView` if not overridden.
    open func loadChildContainerView() -> UIView {
        return UIView()
    }

    /// :nodoc:
    @available(*, unavailable, renamed: "loadChildContainerView")
    public func loadContentViewControllerContainerView() -> UIView {
        fatalError("Unavailable")
    }

    // MARK: - Callbacks

    /// Notifies the view controller that a state transition is to be performed.
    ///
    /// Use this method to prepare view controller representing the given state for display.
    ///
    /// - Parameters:
    ///   - nextState: State that will be transitioned to.
    ///   - animated: Indicates whether the outstanding transition will be animated.
    open func willTransition(to nextState: State, animated: Bool) {
        return
    }

    /// Notifies the view controller that it has finished transitioning to a new state.
    ///
    /// As this method guarantees that a state transition has fully completed, this function is a good place
    /// to call `setNeedsTransition(to:animated:)`, or methods that eventually (asynchronously or synchronously) calls
    /// that method.
    ///
    /// - Parameters:
    ///   - state: State
    ///   - animated: If true, the state transition was animated
    open func didTransition(from previousState: State?, animated: Bool) {
        return
    }

    /// Notifies the view controller that a content view controller will appear.
    ///
    /// - Parameters:
    ///   - viewController: View controller appearing.
    ///   - animated: Indicates whether the appearance is animated.
    open func childWillAppear(_ child: UIViewController, animated: Bool) {
        return
    }

    /// :nodoc:
    @available(*, unavailable, renamed: "childWillAppear")
    public func contentViewControllerWillAppear(_ child: UIViewController, animated: Bool) {
        return
    }

    /// Notifies the view controller that a content view controller did appear.
    ///
    /// This method is well suited as a function to add targets and listeners that should only be present when
    /// the provided content view controller is on screen.
    ///
    /// - Parameters:
    ///   - viewController: View controller appeared.
    ///   - animated: Indicates whether the apperance was animated.
    open func childDidAppear(_ child: UIViewController, animated: Bool) {
        return
    }

    /// :nodoc:
    @available(*, unavailable, renamed: "childDidAppear")
    public func contentViewControllerDidAppear(_ child: UIViewController, animated: Bool) {
        return
    }

    /// Notifies the view controller that a content view controller will disappear.
    /// This method is well suited as a fucntion to remove targets and listerners that should only be present
    /// when the content view controller is on screen.
    ///
    /// - Parameters:
    ///   - viewController: View controller disappearing.
    ///   - animated: Indicates whether the disappearance is animated.
    open func childWillDisappear(_ child: UIViewController, animated: Bool) {
        return
    }

    /// :nodoc:
    @available(*, unavailable, renamed: "childWillDisappear")
    public func contentViewControllerWillDisappear(_ child: UIViewController, animated: Bool) {
        return
    }

    /// Notifies the view controller that a content view controller did disappear.
    ///
    /// - Parameters:
    ///   - viewController: Content view controller disappearad.
    ///   - animated: Indicates whether the disappearance was animated.
    open func childDidDisappear(_ child: UIViewController, animated: Bool) {
        return
    }

    /// :nodoc:
    @available(*, unavailable, renamed: "childDidDisappear")
    public func contentViewControllerDidDisappear(_ child: UIViewController, animated: Bool) {
        return
    }
}

fileprivate extension StateViewController {

    /// Forwards begin appearance methods to child view controllers not currently in a state transition,
    /// and invokes callback methods provided by this class.
    ///
    /// - Parameters:
    ///   - isAppearing: Whether this view controller is appearing
    ///   - animated: Whether the appearance or disappearance of this view controller is animated
    func forwardBeginApperanceTransition(isAppearing: Bool, animated: Bool) {

        // Don't include view controlellers in a state transition.
        // Appearance method forwarding will be performed at a later stage
        let excluded = viewControllersBeingAdded.union(viewControllersBeingRemoved)

        for viewController in children where excluded.contains(viewController) == false {

            // Invoke the appropriate callback method
            if isAppearing {
                childWillAppear(viewController, animated: animated)
            } else {
                childWillDisappear(viewController, animated: animated)
            }

            viewController.beginAppearanceTransition(isAppearing, animated: animated)
        }
    }

    func forwardEndAppearanceTransition(didAppear: Bool, animated: Bool) {

        // Don't include view controlellers in a state transition.
        // Appearance method forwarding will be performed at a later stage.
        let excluded = viewControllersBeingAdded.union(viewControllersBeingRemoved)

        for viewController in children where excluded.contains(viewController) == false {
            viewController.endAppearanceTransition()

            // Invoke the appropriate callback method
            if didAppear {
                childDidAppear(viewController, animated: animated)
            } else {
                childDidDisappear(viewController, animated: animated)
            }
        }
    }
}

fileprivate extension StateViewController {

    @discardableResult
    func beginStateTransition(to state: State, animated: Bool) -> Bool {

        // We may not have made any changes to content view controllers, even though we have changed the state.
        // Therefore, we must be prepare to end the state transition immediately.
        defer {
            endStateTransitionIfNeeded(animated: animated)
        }

        // If we're transitioning between states, we need to abort and wait for the current state
        // transition to finish.
        guard isTransitioningBetweenStates == false else {
            pendingState = (state: state, animated: animated)
            return false
        }

        // Invoke callback method, indicating that we will change state
        willTransition(to: state, animated: animated)

        // Note that we're transitioning from a state
        transitioningFromState = state

        // Update the current state
        stateInternal = state

        // View controllers before the state transition
        let previous = children

        // View controllers after the state transition
        let next = children(for: state)

        // View controllers that were not representing the previous state
        let adding = next.filter { previous.contains($0) == false }

        // View controllers that were representing the previous state, but no longer are
        let removing = previous.filter { next.contains($0) == false }

        // Prepare for removing view controllers
        for viewController in removing {
            willRemoveChild(viewController, animated: animated)
        }

        // Prepare for adding view controllers
        for viewController in adding {
            addChild(viewController, animated: animated)
        }

        #if os(iOS)
        if adding.isEmpty == false || removing.isEmpty == false {
            setNeedsStatusBarAppearanceUpdate()

            if #available(iOS 11, *) {
                setNeedsUpdateOfHomeIndicatorAutoHidden()
                setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            }
        }
        #endif

        // Update the hierarchy of the view controllers that will represent the state being transitioned to.
        updateHierarchy(of: next)
        return true
    }

    /// Performs the state transition, on a per-view controller basis, and ends the state transition if needed.
    func performStateTransition(animated: Bool) {

        // Perform animations for each adding view controller
        for viewController in viewControllersBeingAdded {
            performStateTransition(for: viewController, isAppearing: true) {
                self.didAddChild(viewController, animated: animated)
                self.endStateTransitionIfNeeded(animated: animated)
            }
        }

        // Perform animations for each removing view controller
        for viewController in viewControllersBeingRemoved {
            performStateTransition(for: viewController, isAppearing: false) {
                self.removeChild(viewController, animated: animated)
                self.endStateTransitionIfNeeded(animated: animated)
            }
        }
    }

    /// Ends the state transition if a) an apperance transition is not in progress, b) if no
    /// view controllers are in a state transition.
    ///
    /// - Parameter animated: Whether the state transition was animated.
    func endStateTransitionIfNeeded(animated: Bool) {

        // We're not transitioning from a state, so what gives?
        guard let fromState = transitioningFromState else {
            return
        }

        // We're in an appearance transition. This method will be called again when this is no longer the case.
        guard isInAppearanceTransition == false else {
            return
        }

        // There are still view controllers in a state transition.
        // This method will be called again when this is no longer the case.
        guard viewControllersBeingAdded.union(viewControllersBeingRemoved).isEmpty else {
            return
        }

        // Note that we're no longer transitioning from a state
        transitioningFromState = nil

        // Notify that we're finished transitioning
        didTransition(from: fromState, animated: animated)

        // If we still need another state, let's transition to it immediately.
        if let (state, animated) = pendingState {
            pendingState = nil
            setNeedsStateTransition(to: state, animated: animated)
        }
    }
}

fileprivate extension StateViewController {

    /// Performs the state transition for a given view controller
    ///
    /// - Parameters:
    ///   - viewController: View controller to animate
    ///   - isAppearing: Whether the transition is animated
    ///   - completion: Completion handler
    func performStateTransition(
        for viewController: UIViewController,
        isAppearing: Bool,
        completion: @escaping () -> Void) {

        if let transitioningProtocol = viewController as? StateViewControllerTransitioning {
            transitioningProtocol.stateTransitionWillBegin(isAppearing: isAppearing)
        } else {
            viewController.view.alpha = isAppearing ? 0 : 1
        }

        let transitioningProtocol = viewController as? StateViewControllerTransitioning

        // Set up an animation block
        let animations = {
            // Which performs the animations
            transitioningProtocol?.animateAlongsideStateTransition(isAppearing: isAppearing)

            if transitioningProtocol == nil {
                viewController.view.alpha = isAppearing ? 1 : 0
            }
        }

        let duration = transitioningProtocol?.stateTransitionDuration(isAppearing: isAppearing) ?? 0.35
        let delay = transitioningProtocol?.stateTransitionDelay(isAppearing: isAppearing) ?? 0

        // For iOS 10 and above, we use UIViewPropertyAnimator
        if #available(iOS 10, tvOS 10, *) {
            let animator = UIViewPropertyAnimator(duration: duration, dampingRatio: 1, animations: animations)

            animator.addCompletion { position in

                guard position == .end else {
                    return
                }

                transitioningProtocol?.stateTransitionDidEnd(isAppearing: isAppearing)

                if transitioningProtocol == nil {
                    viewController.view.alpha = isAppearing ? 1 : 0
                }

                completion()
            }

            animator.startAnimation(afterDelay: delay)
            // For iOS 9 and below, we use a spring animations
        } else {
            UIView.animate(
                withDuration: duration,
                delay: delay,
                usingSpringWithDamping: 1,
                initialSpringVelocity: 0,
                options: [],
                animations: animations
            ) { finished in
                    if finished {
                        completion()
                    }
            }
        }
    }
}

fileprivate extension StateViewController {

    func updateHierarchy(of viewControllers: [UIViewController]) {

        let previousSubviews = childContainerView.subviews

        for (index, viewController) in viewControllers.enumerated() {
            viewController.view.translatesAutoresizingMaskIntoConstraints = true
            viewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            viewController.view.bounds.size = childContainerView.bounds.size
            viewController.view.center = childContainerView.center

            childContainerView.insertSubview(viewController.view, at: index)
            viewController.view.layoutIfNeeded()
        }

        // Only proceed if the previous subviews of the content view controller container view
        // differ from the new subviews
        guard previousSubviews.elementsEqual(childContainerView.subviews) == false else {
            return
        }

        // Make sure that contentInsets for scroll views are updated as we go, in case we're targeting
        // iOS 10 or below.
        triggerAutomaticAdjustmentOfScrollViewInsetsIfNeeded()
    }

    /// Prompts the encloding `UINavigationController` and `UITabBarController` to layout their subviews,
    /// triggering them to adjust the scrollview insets
    func triggerAutomaticAdjustmentOfScrollViewInsetsIfNeeded() {

        // Don't do anything if we're on iOS 11 or above
        if #available(iOS 11, *) {
            return
        }

        // Also don't do anything if this view is set to not adjust scroll view insets
        guard automaticallyAdjustsScrollViewInsets else {
            return
        }

        navigationController?.view.setNeedsLayout()
        tabBarController?.view.setNeedsLayout()
    }
}

fileprivate extension StateViewController {

    /// Adds a content view controller to the state view controller
    ///
    /// - Parameters:
    ///   - viewController: View controller to add
    ///   - animated: Whether part of an animated transition
    func addChild(_ child: UIViewController, animated: Bool) {

        guard viewControllersBeingAdded.contains(child) == false else {
            return
        }

        addChild(child)

        // If we're not in an appearance transition, forward appearance methods.
        // If we are, appearance methods will be forwarded at a later time
        if isInAppearanceTransition == false {
            childWillAppear(child, animated: animated)
            child.beginAppearanceTransition(true, animated: animated)
        }

        viewControllersBeingAdded.insert(child)
    }

    func didAddChild(_ child: UIViewController, animated: Bool) {

        guard viewControllersBeingAdded.contains(child) else {
            return
        }

        // If we're not in an appearance transition, forward appearance methods.
        // If we are, appearance methods will be forwarded at a later time
        if isInAppearanceTransition == false {
            child.endAppearanceTransition()
            childDidAppear(child, animated: animated)
        }

        child.didMove(toParent: self)
        viewControllersBeingAdded.remove(child)
    }

    func willRemoveChild(_ child: UIViewController, animated: Bool) {

        guard viewControllersBeingRemoved.contains(child) == false else {
            return
        }

        child.willMove(toParent: nil)

        // If we're not in an appearance transition, forward appearance methods.
        // If we are, appearance methods will be forwarded at a later time
        if isInAppearanceTransition == false {
            childWillDisappear(child, animated: animated)
            child.beginAppearanceTransition(false, animated: animated)
        }

        viewControllersBeingRemoved.insert(child)
    }

    func removeChild(_ child: UIViewController, animated: Bool) {

        guard viewControllersBeingRemoved.contains(child) else {
            return
        }

        child.view.removeFromSuperview()

        // If we're not in an appearance transition, forward appearance methods.
        // If we are, appearance methods will be forwarded at a later time
        if isInAppearanceTransition == false {
            child.endAppearanceTransition()
            childDidDisappear(child, animated: animated)
        }

        child.removeFromParent()
        viewControllersBeingRemoved.remove(child)
    }
}

#endif
