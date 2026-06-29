const brain_activity = @import("brain_activity.zig");

pub const StimulusDispatch = brain_activity.StimulusDispatch;
pub const DerivedActivityLabels = brain_activity.DerivedActivityLabels;
pub const ActivityOrchestration = brain_activity.ActivityOrchestration;
pub const PauseForHostSense = brain_activity.PauseForHostSense;

pub fn deriveActivityLabelsFromState(
    self: *@import("brain.zig").Brain,
    anchor: []const u8,
) !DerivedActivityLabels {
    return brain_activity.deriveActivityLabelsFromState(self, anchor);
}

pub const activityAwaitingHost = brain_activity.activityAwaitingHost;
pub const conversationAwaitingHost = brain_activity.conversationAwaitingHost;
pub const activeActivityId = brain_activity.activeActivityId;
pub const attachActivityFields = brain_activity.attachActivityFields;
pub const ensureActiveActivity = brain_activity.ensureActiveActivity;
pub const classifyTurnContinuation = brain_activity.classifyTurnContinuation;
pub const applyTurnContinuation = brain_activity.applyTurnContinuation;
pub const appendTurnEvents = brain_activity.appendTurnEvents;
pub const pauseActiveActivityForIdle = brain_activity.pauseActiveActivityForIdle;
pub const closeActiveActivity = brain_activity.closeActiveActivity;
pub const archiveActiveActivity = brain_activity.archiveActiveActivity;
pub const pauseForHostSense = brain_activity.pauseForHostSense;
pub const resumeActiveActivity = brain_activity.resumeActiveActivity;
pub const completeActiveActivity = brain_activity.completeActiveActivity;
pub const supersedeActiveActivity = brain_activity.supersedeActiveActivity;
pub const dropActiveCheckpointForInterrupt = brain_activity.dropActiveCheckpointForInterrupt;
pub const clearActiveActivity = brain_activity.clearActiveActivity;
pub const activityView = brain_activity.activityView;
pub const appendTurnEventsWithKind = brain_activity.appendTurnEventsWithKind;
pub const TurnTimelineKind = brain_activity.TurnTimelineKind;
pub const activeConversationPresent = brain_activity.activeConversationPresent;
pub const recordSenseDuringConversation = brain_activity.recordSenseDuringConversation;
pub const appendActivityObservation = brain_activity.appendActivityObservation;
pub const inferActivityKind = brain_activity.inferActivityKind;
pub const inferNewActivityKind = brain_activity.inferNewActivityKind;
pub const isCaptureActivityContext = brain_activity.isCaptureActivityContext;
pub const activityIsInterruptibleWork = brain_activity.activityIsInterruptibleWork;
pub const restorePersistedActivity = brain_activity.restorePersistedActivity;
pub const syncActivityContextFromBrain = brain_activity.syncActivityContextFromBrain;
pub const openActivity = brain_activity.openActivity;
pub const pushActiveOntoStack = brain_activity.pushActiveOntoStack;
pub const collapseActivityStack = brain_activity.collapseActivityStack;
pub const resumeParentFromStack = brain_activity.resumeParentFromStack;
pub const completeSubtaskActivity = brain_activity.completeSubtaskActivity;
pub const abandonOrchestrationSubtask = brain_activity.abandonOrchestrationSubtask;
pub const beginSubtask = brain_activity.beginSubtask;
pub const resumeParentTask = brain_activity.resumeParentTask;
pub const persistActivityStackToStore = brain_activity.persistActivityStackToStore;
