#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin wrapper over the private ReminderKit framework (REMStore / REMSaveRequest).
/// Every call goes through remindd over XPC; remindd grants access from the Reminders TCC
/// permission, so this needs no Full Disk Access, and saves reach iCloud on their own
/// (REMSaveRequest.syncToCloudKit defaults to YES). Every selector and call sequence here was
/// checked by runtime inspection on macOS 27.0.1. IDs are bare uppercase UUIDs.
/// Validation (write guard, versions, parent rules, names) is the caller's job; this layer only
/// translates, and some ReminderKit calls trap on bad input (an unknown color name, for one).
///
/// Reminder change dictionaries, used by addReminder and updateReminder; every key is optional:
///   title     NSString
///   notes     NSString (empty clears)
///   completed NSNumber (BOOL)
///   completeRecurring NSNumber (BOOL): when completing a repeating reminder, save a completed
///             copy and move the reminder to its next occurrence, as Reminders does
///   flagged   NSNumber (BOOL)
///   priority  NSNumber (0 none, 1 high, 5 medium, 9 low)
///   due       NSDateComponents (a time gets the default alarm) or NSNull (clears date and alarms)
///   urgent    NSNumber (BOOL), alarm-style alert for the current user; needs a due time
///   tags      NSArray<NSString *>, replaces all tags
///   repeat    NSDictionary (see below) replaces the recurrence rule; NSNull removes it
///   listId    NSString, moves the reminder to that list (update only)
///   parentId  NSString makes it a subtask of that reminder; NSNull makes it top level
///   sectionId NSString puts it in that section of its (new) list; NSNull takes it out
///   start     NSDateComponents or NSNull
///   earlyAlerts NSArray of @[unit (0 minutes … 4 months), count] replaces the early reminders;
///             NSNull removes them
///   location  NSDictionary {title, latitude, longitude, radius, address, proximity 1 arriving |
///             2 leaving} or {vehicle: 1 getting in | 2 getting out}; replaces the location or
///             vehicle alarm; NSNull removes it
///   contact   NSDictionary {phones, emails} (NSArray<NSString *>), "when messaging"; NSNull removes
///   url       NSString or NSNull
///   addImages NSArray of {path, width, height}; removeImages NSArray of image ids
///   assigneeId NSString (a sharee id of a shared list) or NSNull
///   position  NSDictionary {after | before: reminder id}, among its siblings
///
/// Repeat dictionaries: frequency NSNumber (0 daily, 1 weekly, 2 monthly, 3 yearly, 4 hourly),
/// interval NSNumber, and optionally daysOfWeek (NSArray of @[weekday 1 = Sunday … 7, week
/// number or 0]), daysOfMonth, monthsOfYear (NSArray<NSNumber *>), endDate (NSDate) or count
/// (NSNumber). Read back the same way, plus ical (the RRULE text).
///
/// List change dictionaries: name NSString; color NSDictionary {name: a Reminders color name or
/// custom, hex: @"#RRGGBB"}; icon NSString (an emoji, an emblem name such as nature2, or empty for
/// the default); groupId NSString moves the list into that group, NSNull out of any group;
/// pinned NSNumber; groceries NSNumber (sort items into grocery sections); sorting NSString (a
/// REMSortingStyle value such as manual or priority_desc); position {after | before: list id}.
@interface RKBridge : NSObject

/// Loads ReminderKit and opens a store. Nil when the framework or a class is missing.
+ (nullable instancetype)openWithError:(NSError **)error NS_SWIFT_NAME(open());

/// Lists (not groups): id, name, shared, groupId, color {name, hex}, icon (raw badge), sections
/// [{id, name}] in their order, pinned, groceries, sorting, and for shared lists sharees
/// [{id, name, status, me}].
- (nullable NSArray<NSDictionary<NSString *, id> *> *)listsWithError:(NSError **)error NS_SWIFT_NAME(lists());

/// Groups: id, name.
- (nullable NSArray<NSDictionary<NSString *, id> *> *)groupsWithError:(NSError **)error NS_SWIFT_NAME(groups());

/// The list Reminders uses when none is named.
- (nullable NSString *)defaultListIDWithError:(NSError **)error NS_SWIFT_NAME(defaultListID());

/// Every reminder in a list, including completed ones and subtasks: id, listId, title, notes,
/// completed, completionDate, creationDate, lastModified (NSDate), flagged, priority, hashtags,
/// parentId, sectionId, due (NSDateComponents), urgent, recurring, repeat, alarms
/// (NSDateComponents or a type name).
- (nullable NSArray<NSDictionary<NSString *, id> *> *)remindersInList:(NSString *)listID error:(NSError **)error NS_SWIFT_NAME(reminders(inList:));

/// One reminder with what the list fetch leaves out: earlyAlerts [@[unit, count]].
- (nullable NSDictionary<NSString *, id> *)reminderDetail:(NSString *)reminderID error:(NSError **)error NS_SWIFT_NAME(reminderDetail(_:));

/// Moves a section before or after another one of the same list.
- (BOOL)moveSection:(NSString *)sectionID inList:(NSString *)listID relativeTo:(NSString *)otherID after:(BOOL)after error:(NSError **)error NS_SWIFT_NAME(moveSection(_:inList:relativeTo:after:));

/// Templates: id, name, color, icon.
- (nullable NSArray<NSDictionary<NSString *, id> *> *)templatesWithError:(NSError **)error NS_SWIFT_NAME(templates());
/// Saves a list as a template (Reminders copies its contents in the background); returns its id.
- (nullable NSString *)createTemplateNamed:(NSString *)name fromList:(NSString *)listID includeCompleted:(BOOL)includeCompleted error:(NSError **)error NS_SWIFT_NAME(createTemplate(named:fromList:includeCompleted:));
/// Makes a list from a template; returns the list's id.
- (nullable NSString *)createListFromTemplate:(NSString *)templateID name:(nullable NSString *)name error:(NSError **)error NS_SWIFT_NAME(createList(fromTemplate:name:));
- (BOOL)deleteTemplate:(NSString *)templateID error:(NSError **)error NS_SWIFT_NAME(deleteTemplate(_:));

/// Renames a tag on every reminder that has it, or with a nil name removes it; returns how many
/// reminders changed. Tags compare case-insensitively.
- (nullable NSNumber *)replaceTag:(NSString *)tag with:(nullable NSString *)replacement error:(NSError **)error NS_SWIFT_NAME(replaceTag(_:with:));

/// Creates a list in the default list's account and applies list changes; returns its id.
- (nullable NSString *)createListNamed:(NSString *)name changes:(NSDictionary<NSString *, id> *)changes error:(NSError **)error NS_SWIFT_NAME(createList(named:changes:));

- (BOOL)updateList:(NSString *)listID changes:(NSDictionary<NSString *, id> *)changes error:(NSError **)error NS_SWIFT_NAME(updateList(_:changes:));

/// Removes a list; ReminderKit soft-deletes the reminders still in it.
- (BOOL)deleteList:(NSString *)listID error:(NSError **)error NS_SWIFT_NAME(deleteList(_:));

- (nullable NSString *)createGroupNamed:(NSString *)name error:(NSError **)error NS_SWIFT_NAME(createGroup(named:));
- (BOOL)renameGroup:(NSString *)groupID to:(NSString *)name error:(NSError **)error NS_SWIFT_NAME(renameGroup(_:to:));
- (BOOL)deleteGroup:(NSString *)groupID error:(NSError **)error NS_SWIFT_NAME(deleteGroup(_:));

/// Custom smart lists: id, name, filter (the JSON Reminders stores, as NSString), color, icon.
- (nullable NSArray<NSDictionary<NSString *, id> *> *)smartListsWithError:(NSError **)error NS_SWIFT_NAME(smartLists());

/// Smart list changes: name, filter (JSON NSString), color, icon, as for lists.
- (nullable NSString *)createSmartListNamed:(NSString *)name changes:(NSDictionary<NSString *, id> *)changes error:(NSError **)error NS_SWIFT_NAME(createSmartList(named:changes:));
- (BOOL)updateSmartList:(NSString *)smartListID changes:(NSDictionary<NSString *, id> *)changes error:(NSError **)error NS_SWIFT_NAME(updateSmartList(_:changes:));
- (BOOL)deleteSmartList:(NSString *)smartListID error:(NSError **)error NS_SWIFT_NAME(deleteSmartList(_:));

- (nullable NSString *)createSectionNamed:(NSString *)name inList:(NSString *)listID error:(NSError **)error NS_SWIFT_NAME(createSection(named:inList:));
- (BOOL)renameSection:(NSString *)sectionID inList:(NSString *)listID to:(NSString *)name error:(NSError **)error NS_SWIFT_NAME(renameSection(_:inList:to:));
- (BOOL)deleteSection:(NSString *)sectionID inList:(NSString *)listID error:(NSError **)error NS_SWIFT_NAME(deleteSection(_:inList:));

/// Creates a reminder and applies the changes in the same save. Returns the new id.
- (nullable NSString *)addReminderToList:(NSString *)listID
                                   title:(NSString *)title
                                 changes:(NSDictionary<NSString *, id> *)changes
                                   error:(NSError **)error NS_SWIFT_NAME(addReminder(toList:title:changes:));

- (BOOL)updateReminder:(NSString *)reminderID
               changes:(NSDictionary<NSString *, id> *)changes
                 error:(NSError **)error NS_SWIFT_NAME(updateReminder(_:changes:));

/// Moves reminders to Recently Deleted (ReminderKit's removeFromList is a soft delete) in one save.
- (BOOL)deleteReminders:(NSArray<NSString *> *)reminderIDs error:(NSError **)error NS_SWIFT_NAME(deleteReminders(_:));

/// Of the given ids, the reminders that are soft-deleted and can still be restored:
/// id → {title, completed, parentId}.
- (nullable NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)deletedReminders:(NSArray<NSString *> *)reminderIDs error:(NSError **)error NS_SWIFT_NAME(deletedReminders(_:));

/// Brings soft-deleted reminders back into a list.
- (BOOL)restoreReminders:(NSArray<NSString *> *)reminderIDs toList:(NSString *)listID error:(NSError **)error NS_SWIFT_NAME(restoreReminders(_:toList:));

@end

NS_ASSUME_NONNULL_END
