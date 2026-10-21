#import "RKBridge.h"
#import <objc/message.h>

// ReminderKit objects forward most getters and setters to their storage objects through
// forwardingTargetForSelector:, so respondsToSelector: is not a reliable check. Every public
// method catches the "unrecognized selector" exception instead and reports it as an error.
// Scalar setters use the type encodings observed on macOS 27.0.1: setFlagged: takes NSInteger,
// setPriority: NSUInteger, addHashtagWithType:name: an NSInteger type, recurrence frequency and
// interval NSInteger.

static NSError *RKError(NSString *message) {
    return [NSError errorWithDomain:@"RKBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static id Send(id target, const char *selector) {
    return ((id (*)(id, SEL))objc_msgSend)(target, sel_registerName(selector));
}
static id Send1(id target, const char *selector, id a) {
    return ((id (*)(id, SEL, id))objc_msgSend)(target, sel_registerName(selector), a);
}
static id Send2(id target, const char *selector, id a, id b) {
    return ((id (*)(id, SEL, id, id))objc_msgSend)(target, sel_registerName(selector), a, b);
}
static id Send3(id target, const char *selector, id a, id b, id c) {
    return ((id (*)(id, SEL, id, id, id))objc_msgSend)(target, sel_registerName(selector), a, b, c);
}
static BOOL SendBool(id target, const char *selector) {
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, sel_registerName(selector));
}
static long long SendInteger(id target, const char *selector) {
    return ((long long (*)(id, SEL))objc_msgSend)(target, sel_registerName(selector));
}
// Void methods need their own casts: called through an id-returning cast, ARC retains
// whatever is left in x0 and crashes.
static void SendVoid(id target, const char *selector) {
    ((void (*)(id, SEL))objc_msgSend)(target, sel_registerName(selector));
}
static void SendVoid1(id target, const char *selector, id a) {
    ((void (*)(id, SEL, id))objc_msgSend)(target, sel_registerName(selector), a);
}
static void SendVoid2(id target, const char *selector, id a, id b) {
    ((void (*)(id, SEL, id, id))objc_msgSend)(target, sel_registerName(selector), a, b);
}
static double SendDouble(id target, const char *selector) {
    return ((double (*)(id, SEL))objc_msgSend)(target, sel_registerName(selector));
}
static void SendSetBool(id target, const char *selector, BOOL value) {
    ((void (*)(id, SEL, BOOL))objc_msgSend)(target, sel_registerName(selector), value);
}
static id SendWithError(id target, const char *selector, NSError **error) {
    return ((id (*)(id, SEL, NSError **))objc_msgSend)(target, sel_registerName(selector), error);
}
static id Send1WithError(id target, const char *selector, id a, NSError **error) {
    return ((id (*)(id, SEL, id, NSError **))objc_msgSend)(target, sel_registerName(selector), a, error);
}

static NSString *UUIDOf(id objectID) {
    if (!objectID) return nil;
    NSUUID *uuid = Send(objectID, "uuid");
    return uuid.UUIDString;
}

/// Reads an optional property; a selector the object does not forward reads as nil.
static id Get(id target, const char *selector) {
    if (!target) return nil;
    @try {
        return Send(target, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSError *ExceptionError(NSException *exception) {
    return RKError(exception.reason ?: exception.name);
}

@implementation RKBridge {
    id _store;
    Class _saveRequestClass;
    id _sectionsView;
}

+ (instancetype)openWithError:(NSError **)error {
    if (![[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/ReminderKit.framework"] load]) {
        if (error) *error = RKError(@"ReminderKit.framework could not be loaded");
        return nil;
    }
    Class storeClass = NSClassFromString(@"REMStore");
    Class saveRequestClass = NSClassFromString(@"REMSaveRequest");
    if (!storeClass || !saveRequestClass) {
        if (error) *error = RKError(@"REMStore or REMSaveRequest is missing from ReminderKit");
        return nil;
    }
    RKBridge *bridge = [[RKBridge alloc] init];
    bridge->_saveRequestClass = saveRequestClass;
    // Without the private remindd entitlement, remindd serves a user-interactive request on its
    // ordinary XPC queue, so this only asks for priority.
    bridge->_store = ((id (*)(id, SEL, BOOL))objc_msgSend)([storeClass alloc], sel_registerName("initUserInteractive:"), YES);
    Class sectionsViewClass = NSClassFromString(@"REMListSectionsDataView");
    if (sectionsViewClass) bridge->_sectionsView = Send1([sectionsViewClass alloc], "initWithStore:", bridge->_store);
    return bridge;
}

#pragma mark - Raw objects

- (NSArray *)rawListsWithError:(NSError **)error {
    NSArray *lists = SendWithError(_store, "fetchEligibleDefaultListsWithError:", error);
    if (!lists) return nil;
    NSMutableArray *result = [NSMutableArray array];
    for (id list in lists) {
        if (!SendBool(list, "isGroup")) [result addObject:list];
    }
    return result;
}

/// Groups are not among the eligible default lists; only the full enumeration has them.
- (NSArray *)rawGroups {
    NSMutableArray *groups = [NSMutableArray array];
    ((void (*)(id, SEL, void (^)(id, BOOL *)))objc_msgSend)(_store, sel_registerName("enumerateAllGroupsAndListsWithBlock:"), ^(id list, BOOL *stop) {
        if (SendBool(list, "isGroup")) [groups addObject:list];
    });
    return groups;
}

- (id)rawList:(NSString *)listID error:(NSError **)error {
    NSArray *lists = [self rawListsWithError:error];
    if (!lists) return nil;
    for (id list in lists) {
        if ([UUIDOf(Send(list, "objectID")) isEqualToString:listID.uppercaseString]) return list;
    }
    if (error) *error = RKError([NSString stringWithFormat:@"No list with id %@", listID]);
    return nil;
}

- (id)rawGroup:(NSString *)groupID error:(NSError **)error {
    for (id group in [self rawGroups]) {
        if ([UUIDOf(Send(group, "objectID")) isEqualToString:groupID.uppercaseString]) return group;
    }
    if (error) *error = RKError([NSString stringWithFormat:@"No group with id %@", groupID]);
    return nil;
}

- (NSArray *)rawRemindersInList:(id)list error:(NSError **)error {
    return Send1WithError(_store, "fetchRemindersForEventKitBridgingWithListIDs:error:", @[Send(list, "objectID")], error);
}

- (id)rawReminder:(NSString *)reminderID error:(NSError **)error {
    NSArray *lists = [self rawListsWithError:error];
    if (!lists) return nil;
    for (id list in lists) {
        NSArray *reminders = [self rawRemindersInList:list error:error];
        if (!reminders) return nil;
        for (id reminder in reminders) {
            if ([UUIDOf(Send(reminder, "objectID")) isEqualToString:reminderID.uppercaseString]) return reminder;
        }
    }
    if (error) *error = RKError([NSString stringWithFormat:@"No reminder with id %@", reminderID]);
    return nil;
}

- (NSArray *)rawSectionsInList:(id)list error:(NSError **)error {
    return Send1WithError(_store, "fetchListSectionsWithListObjectID:error:", Send(list, "objectID"), error) ?: @[];
}

- (id)rawSection:(NSString *)sectionID inList:(id)list error:(NSError **)error {
    for (id section in [self rawSectionsInList:list error:error]) {
        if ([UUIDOf(Send(section, "objectID")) isEqualToString:sectionID.uppercaseString]) return section;
    }
    if (error) *error = RKError([NSString stringWithFormat:@"No section with id %@", sectionID]);
    return nil;
}

- (id)reminderObjectID:(NSString *)reminderID {
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:reminderID];
    return uuid ? Send1(NSClassFromString(@"REMReminder"), "objectIDWithUUID:", uuid) : nil;
}

- (id)newSaveRequest {
    return Send1([_saveRequestClass alloc], "initWithStore:", _store);
}

- (BOOL)save:(id)request error:(NSError **)error {
    return ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(request, sel_registerName("saveSynchronouslyWithError:"), error);
}

- (id)defaultAccountWithError:(NSError **)error {
    id list = SendWithError(_store, "fetchDefaultListWithError:", error);
    if (!list) {
        if (error && !*error) *error = RKError(@"Reminders has no default list");
        return nil;
    }
    return Send(list, "account");
}

#pragma mark - Reading

static NSDictionary *ColorInfo(id color) {
    if (!color) return nil;
    NSString *name = Get(color, "ckSymbolicColorName") ?: @"custom";
    NSString *hex = Get(color, "hexString") ?: @"";
    return @{@"name": name, @"hex": hex};
}

- (NSArray *)listsWithError:(NSError **)error {
    @try {
        NSArray *lists = [self rawListsWithError:error];
        if (!lists) return nil;
        NSMutableArray *result = [NSMutableArray array];
        for (id list in lists) {
            NSMutableDictionary *item = [@{
                @"id": UUIDOf(Send(list, "objectID")) ?: @"",
                @"name": Send(Send(list, "storage"), "name") ?: @"",
                @"shared": @(SendBool(list, "isShared")),
            } mutableCopy];
            NSString *groupID = UUIDOf(Get(Get(list, "parentList"), "objectID"));
            if (groupID) item[@"groupId"] = groupID;
            NSDictionary *color = ColorInfo(Get(list, "color"));
            if (color) item[@"color"] = color;
            NSString *icon = Get(list, "badgeEmblem");
            if (icon.length) item[@"icon"] = icon;
            NSMutableArray *sections = [NSMutableArray array];
            for (id section in [self rawSectionsInList:list error:nil]) {
                [sections addObject:@{@"id": UUIDOf(Send(section, "objectID")) ?: @"", @"name": Get(section, "displayName") ?: @""}];
            }
            item[@"sections"] = sections;
            id storage = Send(list, "storage");
            item[@"pinned"] = @(SendBool(list, "isPinned"));
            item[@"groceries"] = @(SendBool(storage, "shouldCategorizeGroceryItems"));
            NSString *sorting = Get(storage, "sortingStyle");
            if (sorting) item[@"sorting"] = sorting;
            if (SendBool(list, "isShared")) item[@"sharees"] = [self shareesOfList:list];
            [result addObject:item];
        }
        return result;
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return nil;
    }
}

static NSString *ShareeName(id sharee) {
    NSString *formatted = Get(sharee, "formattedName");
    if (formatted.length) return formatted;
    NSString *joined = [[@[Get(sharee, "firstName") ?: @"", Get(sharee, "lastName") ?: @""] componentsJoinedByString:@" "]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (joined.length) return joined;
    return Get(sharee, "displayName") ?: Get(sharee, "address") ?: @"";
}

/// People on a shared list; `me` marks the current user, whose sharee id is the list's
/// currentUserShareParticipantID.
- (NSArray *)shareesOfList:(id)list {
    NSString *me = Get(Send(list, "storage"), "currentUserShareParticipantID");
    NSMutableArray *result = [NSMutableArray array];
    for (id sharee in (NSArray *)Get(Get(list, "shareeContext"), "sharees") ?: @[]) {
        NSString *shareeID = UUIDOf(Send(sharee, "objectID")) ?: @"";
        [result addObject:@{
            @"id": shareeID, @"name": ShareeName(sharee), @"status": @(SendInteger(sharee, "status")),
            @"me": @([shareeID caseInsensitiveCompare:me ?: @""] == NSOrderedSame),
        }];
    }
    return result;
}

- (id)rawSharee:(NSString *)shareeID inList:(id)list {
    for (id sharee in (NSArray *)Get(Get(list, "shareeContext"), "sharees") ?: @[]) {
        if ([UUIDOf(Send(sharee, "objectID")) caseInsensitiveCompare:shareeID] == NSOrderedSame) return sharee;
    }
    return nil;
}

- (NSArray *)groupsWithError:(NSError **)error {
    @try {
        NSMutableArray *result = [NSMutableArray array];
        for (id group in [self rawGroups]) {
            [result addObject:@{@"id": UUIDOf(Send(group, "objectID")) ?: @"", @"name": Send(Send(group, "storage"), "name") ?: @""}];
        }
        return result;
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return nil;
    }
}

- (NSString *)defaultListIDWithError:(NSError **)error {
    @try {
        id list = SendWithError(_store, "fetchDefaultListWithError:", error);
        if (!list) {
            if (error && !*error) *error = RKError(@"Reminders has no default list");
            return nil;
        }
        return UUIDOf(Send(list, "objectID"));
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return nil;
    }
}

static NSDictionary *RepeatInfo(id rule) {
    NSMutableDictionary *info = [@{
        @"frequency": @(SendInteger(rule, "frequency")),
        @"interval": @(SendInteger(rule, "interval")),
    } mutableCopy];
    NSMutableArray *days = [NSMutableArray array];
    for (id day in (NSArray *)Get(rule, "daysOfTheWeek") ?: @[]) {
        [days addObject:@[@(SendInteger(day, "dayOfTheWeek")), @(SendInteger(day, "weekNumber"))]];
    }
    if (days.count) info[@"daysOfWeek"] = days;
    NSArray *monthDays = Get(rule, "daysOfTheMonth");
    if (monthDays.count) info[@"daysOfMonth"] = monthDays;
    NSArray *months = Get(rule, "monthsOfTheYear");
    if (months.count) info[@"monthsOfYear"] = months;
    id end = Get(rule, "recurrenceEnd");
    if (end) {
        if (SendBool(end, "usesEndDate")) {
            NSDate *date = Get(end, "endDate");
            if (date) info[@"endDate"] = date;
        } else {
            info[@"count"] = @(SendInteger(end, "occurrenceCount"));
        }
    }
    NSString *ical = Get(rule, "iCalendarDescription");
    if (ical) info[@"ical"] = ical;
    return info;
}

/// A location or vehicle alarm trigger as a dictionary; nil for any other trigger.
static NSDictionary *LocationInfo(id trigger) {
    if ([trigger isKindOfClass:NSClassFromString(@"REMAlarmVehicleTrigger")]) return @{@"vehicle": @(SendInteger(trigger, "event"))};
    if (![trigger isKindOfClass:NSClassFromString(@"REMAlarmLocationTrigger")]) return nil;
    id place = Get(trigger, "structuredLocation");
    NSMutableDictionary *info = [@{
        @"proximity": @(SendInteger(trigger, "proximity")), @"title": Get(place, "title") ?: @"",
        @"latitude": @(SendDouble(place, "latitude")), @"longitude": @(SendDouble(place, "longitude")),
        @"radius": @(SendDouble(place, "radius")),
    } mutableCopy];
    NSString *address = Get(place, "address");
    if (address.length) info[@"address"] = address;
    return info;
}

/// Everything the tools read about a reminder.
- (NSMutableDictionary *)infoForReminder:(id)reminder listID:(NSString *)listUUID sections:(BOOL)hasSections {
    NSMutableArray *tags = [NSMutableArray array];
    for (id tag in (NSSet *)Get(reminder, "hashtags") ?: [NSSet set]) {
        NSString *name = Send(tag, "name");
        if (name) [tags addObject:name];
    }
    NSMutableArray *alarms = [NSMutableArray array];
    NSDictionary *place = nil;
    for (id alarm in (NSArray *)Get(reminder, "alarms") ?: @[]) {
        if (SendBool(alarm, "isSnooze")) continue;
        id trigger = Get(alarm, "trigger");
        NSDictionary *location = LocationInfo(trigger);
        if (location) {
            place = location;
            continue;
        }
        NSDateComponents *components = Get(trigger, "dateComponents");
        if ([components isKindOfClass:[NSDateComponents class]]) [alarms addObject:components];
        else [alarms addObject:NSStringFromClass([trigger class] ?: [alarm class])];
    }
    NSMutableDictionary *item = [@{
        @"id": UUIDOf(Send(reminder, "objectID")) ?: @"",
        @"listId": listUUID,
        @"title": Send(reminder, "titleAsString") ?: @"",
        @"completed": @(SendBool(reminder, "isCompleted")),
        @"flagged": @(SendInteger(reminder, "flagged")),
        @"priority": @(SendInteger(reminder, "priority")),
        @"hashtags": [tags sortedArrayUsingSelector:@selector(compare:)],
        @"alarms": alarms,
    } mutableCopy];
    NSString *notes = Get(reminder, "notesAsString");
    if (notes.length) item[@"notes"] = notes;
    NSString *parent = UUIDOf(Get(reminder, "parentReminderID"));
    if (parent) item[@"parentId"] = parent;
    NSDateComponents *due = Get(reminder, "dueDateComponents");
    if ([due isKindOfClass:[NSDateComponents class]]) item[@"due"] = due;
    for (NSString *key in @[@"completionDate", @"creationDate", @"lastModifiedDate"]) {
        NSDate *date = Get(reminder, key.UTF8String);
        if ([date isKindOfClass:[NSDate class]]) item[[key isEqualToString:@"lastModifiedDate"] ? @"lastModified" : key] = date;
    }
    @try {
        item[@"urgent"] = @(SendBool(reminder, "isUrgentStateEnabledForCurrentUser"));
        item[@"recurring"] = @(SendBool(reminder, "isRecurrent"));
    } @catch (__unused NSException *exception) {
    }
    id rule = [(NSArray *)Get(reminder, "recurrenceRules") firstObject];
    if (rule) item[@"repeat"] = RepeatInfo(rule);
    if (place) item[@"location"] = place;
    NSDateComponents *start = Get(reminder, "startDateComponents");
    if ([start isKindOfClass:[NSDateComponents class]]) item[@"start"] = start;
    id contact = Get(reminder, "contactHandles");
    NSArray *phones = Get(contact, "phones"), *emails = Get(contact, "emails");
    if (phones.count || emails.count) item[@"contact"] = @{@"phones": phones ?: @[], @"emails": emails ?: @[]};
    id attachments = Get(reminder, "attachmentContext");
    NSMutableArray *urls = [NSMutableArray array];
    for (id attachment in (NSArray *)Get(attachments, "urlAttachments") ?: @[]) {
        NSString *url = [Get(attachment, "url") absoluteString];
        if (url) [urls addObject:url];
    }
    if (urls.count) item[@"urls"] = urls;
    NSMutableArray *images = [NSMutableArray array];
    for (id image in (NSArray *)Get(attachments, "imageAttachments") ?: @[]) {
        NSMutableDictionary *info = [@{
            @"id": UUIDOf(Send(image, "objectID")) ?: @"", @"type": Get(image, "uti") ?: @"",
            @"width": @(SendInteger(image, "width")), @"height": @(SendInteger(image, "height")),
            @"size": @(SendInteger(image, "fileSize")),
        } mutableCopy];
        NSString *path = [Get(image, "fileURL") path];
        if (path) info[@"path"] = path;
        [images addObject:info];
    }
    if (images.count) item[@"images"] = images;
    NSString *assignee = UUIDOf(Get(Get(Get(reminder, "assignmentContext"), "currentAssignment"), "assigneeID"));
    if (assignee) item[@"assigneeId"] = assignee;
    if (hasSections && _sectionsView) {
        id section = Send1WithError(_sectionsView, "fetchListSectionWithReminderID:error:", Send(reminder, "objectID"), nil);
        NSString *sectionID = UUIDOf(Get(section, "objectID"));
        if (sectionID) item[@"sectionId"] = sectionID;
    }
    return item;
}

- (NSArray *)remindersInList:(NSString *)listID error:(NSError **)error {
    @try {
        id list = [self rawList:listID error:error];
        if (!list) return nil;
        NSArray *reminders = [self rawRemindersInList:list error:error];
        if (!reminders) return nil;
        BOOL hasSections = [self rawSectionsInList:list error:nil].count > 0;
        NSMutableArray *result = [NSMutableArray array];
        for (id reminder in reminders) [result addObject:[self infoForReminder:reminder listID:listID.uppercaseString sections:hasSections]];
        return result;
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return nil;
    }
}

/// The early reminders are only in a fetch that asks for them.
- (id)rawReminderWithAlerts:(NSString *)reminderID error:(NSError **)error {
    id objectID = [self reminderObjectID:reminderID];
    if (!objectID) {
        if (error) *error = RKError([NSString stringWithFormat:@"No reminder with id %@", reminderID]);
        return nil;
    }
    id options = Send(NSClassFromString(@"REMReminderFetchOptions"), "fetchOptionsIncludingDueDateDeltaAlerts");
    NSDictionary *found = ((id (*)(id, SEL, id, id, NSError **))objc_msgSend)(
        _store, sel_registerName("fetchRemindersWithObjectIDs:fetchOptions:error:"), @[objectID], options, error);
    id reminder = found.allValues.firstObject;
    if (!reminder && error && !*error) *error = RKError([NSString stringWithFormat:@"No reminder with id %@", reminderID]);
    return reminder;
}

static NSArray *EarlyAlerts(id reminder) {
    NSMutableArray *alerts = [NSMutableArray array];
    for (id alert in (NSArray *)Get(Get(reminder, "dueDateDeltaAlertContext"), "dueDateDeltaAlerts") ?: @[]) {
        id delta = Get(alert, "dueDateDelta");
        if (delta) [alerts addObject:@[@(SendInteger(delta, "unit")), @(SendInteger(delta, "count"))]];
    }
    return alerts;
}

- (NSDictionary *)reminderDetail:(NSString *)reminderID error:(NSError **)error {
    @try {
        id reminder = [self rawReminderWithAlerts:reminderID error:error];
        if (!reminder) return nil;
        NSString *listID = UUIDOf(Get(reminder, "listID"));
        id list = listID ? [self rawList:listID error:nil] : nil;
        BOOL hasSections = list && [self rawSectionsInList:list error:nil].count > 0;
        NSMutableDictionary *item = [self infoForReminder:reminder listID:listID ?: @"" sections:hasSections];
        item[@"earlyAlerts"] = EarlyAlerts(reminder);
        return item;
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return nil;
    }
}

#pragma mark - Lists and groups

static id MakeColor(NSDictionary *color) {
    Class colorClass = NSClassFromString(@"REMColor");
    NSString *name = color[@"name"], *hex = color[@"hex"];
    if (![name isEqualToString:@"custom"]) return Send2([colorClass alloc], "initWithCKSymbolicColorName:hexString:", name, hex);
    return Send1(colorClass, "colorWithHexString:", hex);
}

/// An emoji, an emblem name such as nature2, or nil for the default icon.
static id MakeBadge(NSString *icon) {
    if (!icon.length) return nil;
    Class badgeClass = NSClassFromString(@"REMListBadge");
    BOOL emblem = [icon canBeConvertedToEncoding:NSASCIIStringEncoding];
    return Send1([badgeClass alloc], emblem ? "initWithEmblem:" : "initWithEmoji:", icon);
}

/// Applies list changes to a list change item inside `request`.
- (BOOL)applyList:(NSDictionary *)changes to:(id)listChange request:(id)request account:(id)account error:(NSError **)error {
    if ([changes[@"name"] isKindOfClass:[NSString class]]) SendVoid1(Send(listChange, "storage"), "setName:", changes[@"name"]);
    if ([changes[@"color"] isKindOfClass:[NSDictionary class]]) SendVoid1(listChange, "setColor:", MakeColor(changes[@"color"]));
    if ([changes[@"icon"] isKindOfClass:[NSString class]]) SendVoid1(Send(listChange, "appearanceContext"), "setBadge:", MakeBadge(changes[@"icon"]));
    id groupID = changes[@"groupId"];
    if ([groupID isKindOfClass:[NSString class]]) {
        id group = [self rawGroup:groupID error:error];
        if (!group) return NO;
        SendVoid1(Send(Send1(request, "updateList:", group), "sublistContext"), "addListChangeItem:", listChange);
    } else if (groupID == [NSNull null]) {
        SendVoid1(Send1(request, "updateAccount:", account), "addListChangeItem:", listChange);
    }
    if (changes[@"pinned"]) SendSetBool(listChange, "setIsPinned:", [changes[@"pinned"] boolValue]);
    if (changes[@"groceries"]) {
        id grocery = Send(listChange, "groceryContextChangeItem");
        BOOL on = [changes[@"groceries"] boolValue];
        if (on && !Get(grocery, "groceryLocaleID")) SendVoid1(grocery, "setGroceryLocaleID:", NSLocale.currentLocale.localeIdentifier);
        SendSetBool(grocery, "setShouldCategorizeGroceryItems:", on);
    }
    if ([changes[@"sorting"] isKindOfClass:[NSString class]]) SendVoid1(Send(listChange, "storage"), "setSortingStyle:", changes[@"sorting"]);
    NSDictionary *position = changes[@"position"];
    if ([position isKindOfClass:[NSDictionary class]]) {
        BOOL after = position[@"after"] != nil;
        id neighbor = [self rawList:(after ? position[@"after"] : position[@"before"]) error:error];
        if (!neighbor) return NO;
        // Siblings are ordered by their container: the group they are in, or the account.
        id group = Get(neighbor, "parentList");
        id container = group ? Send(Send1(request, "updateList:", group), "sublistContext") : Send1(request, "updateAccount:", account);
        SendVoid2(container, after ? "insertListChangeItem:afterListChangeItem:" : "insertListChangeItem:beforeListChangeItem:",
                  listChange, Send1(request, "updateList:", neighbor));
    }
    return YES;
}

- (NSString *)createListNamed:(NSString *)name changes:(NSDictionary *)changes error:(NSError **)error {
    @try {
        id account = [self defaultAccountWithError:error];
        if (!account) return nil;
        id request = [self newSaveRequest];
        id listChange = Send3(request, "addListWithName:toAccountChangeItem:listObjectID:", name, Send1(request, "updateAccount:", account), nil);
        if (!listChange) {
            if (error) *error = RKError(@"addListWithName returned nil");
            return nil;
        }
        NSMutableDictionary *rest = [changes mutableCopy];
        [rest removeObjectForKey:@"name"];
        if (rest[@"groupId"] == [NSNull null]) [rest removeObjectForKey:@"groupId"];
        if (![self applyList:rest to:listChange request:request account:account error:error]) return nil;
        if (![self save:request error:error]) return nil;
        return UUIDOf(Send(listChange, "objectID"));
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return nil;
    }
}

- (BOOL)updateList:(NSString *)listID changes:(NSDictionary *)changes error:(NSError **)error {
    @try {
        id list = [self rawList:listID error:error];
        if (!list) return NO;
        id request = [self newSaveRequest];
        if (![self applyList:changes to:Send1(request, "updateList:", list) request:request account:Send(list, "account") error:error]) return NO;
        return [self save:request error:error];
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return NO;
    }
}

- (BOOL)deleteList:(NSString *)listID error:(NSError **)error {
    @try {
        id list = [self rawList:listID error:error];
        if (!list) return NO;
        id request = [self newSaveRequest];
        SendVoid(Send1(request, "updateList:", list), "removeFromParent");
        return [self save:request error:error];
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return NO;
    }
}

- (NSString *)createGroupNamed:(NSString *)name error:(NSError **)error {
    @try {
        id account = [self defaultAccountWithError:error];
        if (!account) return nil;
        id request = [self newSaveRequest];
        id groupContext = Send(Send1(request, "updateAccount:", account), "groupContext");
        id group = Send3(request, "addGroupWithName:toAccountGroupContextChangeItem:groupObjectID:", name, groupContext, nil);
        if (!group) {
            if (error) *error = RKError(@"addGroupWithName returned nil");
            return nil;
        }
        if (![self save:request error:error]) return nil;
        return UUIDOf(Send(group, "objectID"));
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return nil;
    }
}

- (BOOL)renameGroup:(NSString *)groupID to:(NSString *)name error:(NSError **)error {
    @try {
        id group = [self rawGroup:groupID error:error];
        if (!group) return NO;
        id request = [self newSaveRequest];
        SendVoid1(Send(Send1(request, "updateList:", group), "storage"), "setName:", name);
        return [self save:request error:error];
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return NO;
    }
}

- (BOOL)deleteGroup:(NSString *)groupID error:(NSError **)error {
    @try {
        id group = [self rawGroup:groupID error:error];
        if (!group) return NO;
        id request = [self newSaveRequest];
        SendVoid(Send1(request, "updateList:", group), "removeFromParent");
        return [self save:request error:error];
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return NO;
    }
}

#pragma mark - Smart lists

- (NSArray *)rawSmartListsWithError:(NSError **)error {
    return SendWithError(_store, "fetchCustomSmartListsWithError:", error);
}

- (id)rawSmartList:(NSString *)smartListID error:(NSError **)error {
    NSArray *smartLists = [self rawSmartListsWithError:error];
    if (!smartLists) return nil;
    for (id smartList in smartLists) {
        if ([UUIDOf(Send(smartList, "objectID")) isEqualToString:smartListID.uppercaseString]) return smartList;
    }
    if (error) *error = RKError([NSString stringWithFormat:@"No smart list with id %@", smartListID]);
    return nil;
}

- (NSArray *)smartListsWithError:(NSError **)error {
    @try {
        NSArray *smartLists = [self rawSmartListsWithError:error];
        if (!smartLists) return nil;
        NSMutableArray *result = [NSMutableArray array];
        for (id smartList in smartLists) {
            id context = Get(smartList, "customContext");
            NSMutableDictionary *item = [@{
                @"id": UUIDOf(Send(smartList, "objectID")) ?: @"",
                @"name": Get(context, "name") ?: @"",
            } mutableCopy];
            NSData *filter = Get(smartList, "filterData");
            if (filter) item[@"filter"] = [[NSString alloc] initWithData:filter encoding:NSUTF8StringEncoding] ?: @"";
            NSDictionary *color = ColorInfo(Get(context, "color"));
            if (color) item[@"color"] = color;
            NSString *icon = Get(Get(context, "badge"), "rawValue");
            if (icon.length) item[@"icon"] = icon;
            [result addObject:item];
        }
        return result;
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return nil;
    }
}

- (void)applySmartList:(NSDictionary *)changes to:(id)smartListChange {
    id context = Send(smartListChange, "customContext");
    if ([changes[@"name"] isKindOfClass:[NSString class]]) SendVoid1(context, "setName:", changes[@"name"]);
    if ([changes[@"color"] isKindOfClass:[NSDictionary class]]) SendVoid1(context, "setColor:", MakeColor(changes[@"color"]));
    if ([changes[@"icon"] isKindOfClass:[NSString class]]) SendVoid1(context, "setBadge:", MakeBadge(changes[@"icon"]));
    if ([changes[@"filter"] isKindOfClass:[NSString class]]) {
        SendVoid1(smartListChange, "setFilterData:", [changes[@"filter"] dataUsingEncoding:NSUTF8StringEncoding]);
        // Reminders marks custom smart lists with the app version that introduced filters and
        // shows no filters for one marked 0; storing filterData directly does not set it.
        id storage = Send(smartListChange, "storage");
        const long long filtersVersion = 20220430;
        if (SendInteger(storage, "minimumSupportedVersion") < filtersVersion) {
            ((void (*)(id, SEL, long long))objc_msgSend)(storage, sel_registerName("setMinimumSupportedVersion:"), filtersVersion);
        }
        if (SendInteger(storage, "effectiveMinimumSupportedVersion") < filtersVersion) {
            ((void (*)(id, SEL, long long))objc_msgSend)(storage, sel_registerName("setEffectiveMinimumSupportedVersion:"), filtersVersion);
        }
    }
}

- (NSString *)createSmartListNamed:(NSString *)name changes:(NSDictionary *)changes error:(NSError **)error {
    @try {
        id account = [self defaultAccountWithError:error];
        if (!account) return nil;
        id request = [self newSaveRequest];
        id smartList = Send3(request, "addCustomSmartListWithName:toAccountChangeItem:smartListObjectID:", name, Send1(request, "updateAccount:", account), nil);
        if (!smartList) {
            if (error) *error = RKError(@"addCustomSmartListWithName returned nil");
            return nil;
        }
        NSMutableDictionary *rest = [changes mutableCopy];
        [rest removeObjectForKey:@"name"];
        [self applySmartList:rest to:smartList];
        if (![self save:request error:error]) return nil;
        return UUIDOf(Send(smartList, "objectID"));
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return nil;
    }
}

- (BOOL)updateSmartList:(NSString *)smartListID changes:(NSDictionary *)changes error:(NSError **)error {
    @try {
        id smartList = [self rawSmartList:smartListID error:error];
        if (!smartList) return NO;
        id request = [self newSaveRequest];
        [self applySmartList:changes to:Send1(request, "updateSmartList:", smartList)];
        return [self save:request error:error];
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return NO;
    }
}

- (BOOL)deleteSmartList:(NSString *)smartListID error:(NSError **)error {
    @try {
        id smartList = [self rawSmartList:smartListID error:error];
        if (!smartList) return NO;
        id account = [self defaultAccountWithError:error];
        if (!account) return NO;
        id request = [self newSaveRequest];
        SendVoid1(Send1(request, "updateSmartList:", smartList), "removeFromParentWithAccountChangeItem:", Send1(request, "updateAccount:", account));
        return [self save:request error:error];
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return NO;
    }
}

// remindd evaluates a smart list's filter itself, through ReminderKitInternal's Swift invocation
// REMRemindersListDataView_CustomSmartListInvocation. Its parameters are a binary property list
// of the Codable keys below (each one is required), and the storages must carry the smart list's
// and its account's storage, keyed by object id. The result's model.reminders lists what the
// smart list shows, subtasks that match on their own rows; fetchSubtasks on would add every
// subtask of a matching parent, matching or not, so it stays off.
- (NSDictionary *)smartListContentsIncludingCompleted:(BOOL)includeCompleted error:(NSError **)error {
    @try {
        [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/ReminderKitInternal.framework"] load];
        Class invocationClass = NSClassFromString(@"REMRemindersListDataView_CustomSmartListInvocation");
        if (!invocationClass) {
            if (error) *error = RKError(@"ReminderKitInternal has no custom smart list fetch");
            return nil;
        }
        NSArray *smartLists = [self rawSmartListsWithError:error];
        if (!smartLists) return nil;
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        for (id smartList in smartLists) {
            NSString *smartListID = UUIDOf(Send(smartList, "objectID"));
            NSDictionary *parameters = @{
                @"smartList": @{@"objectIDUUID": smartListID},
                @"sortingStyle": @{@"base": @"default"},
                @"showCompleted": @{@"base": includeCompleted ? @"on" : @"off"},
                @"countCompleted": @NO,
                @"remindersPrefetch": @{@"base": @"none"},
                @"fetchSubtasks": @"off",
                @"shouldFetchManualOrderingID": @NO,
            };
            NSData *data = [NSPropertyListSerialization dataWithPropertyList:parameters format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
            if (!data) return nil;
            NSMutableDictionary *storages = [NSMutableDictionary dictionary];
            storages[Send(smartList, "objectID")] = Send(smartList, "storage");
            id account = Get(smartList, "account");
            if (account) storages[Send(account, "objectID")] = Send(account, "storage");
            id invocation = Send1([invocationClass alloc], "initWithFetchResultTokenToDiffAgainst:", nil);
            id answer = ((id (*)(id, SEL, id, id, id, NSError **))objc_msgSend)(
                _store, sel_registerName("resultFromPerformingSwiftInvocation:parametersData:storages:error:"), invocation, data, storages, error);
            if (!answer) return nil;
            NSDictionary *decoded = [NSPropertyListSerialization propertyListWithData:Send(answer, "resultData") options:0 format:nil error:error];
            NSDictionary *model = [decoded isKindOfClass:[NSDictionary class]] ? decoded[@"model"] : nil;
            NSArray *rows = [model isKindOfClass:[NSDictionary class]] ? model[@"reminders"] : nil;
            if (![rows isKindOfClass:[NSArray class]]) {
                if (error) *error = RKError(@"The custom smart list fetch returned no reminders model");
                return nil;
            }
            NSMutableArray *reminderIDs = [NSMutableArray array];
            for (NSDictionary *row in rows) {
                NSDictionary *objectID = [row isKindOfClass:[NSDictionary class]] ? row[@"objectID"] : nil;
                NSString *uuid = [objectID isKindOfClass:[NSDictionary class]] ? objectID[@"uuid"] : nil;
                if ([uuid isKindOfClass:[NSString class]]) [reminderIDs addObject:uuid.uppercaseString];
            }
            result[smartListID] = reminderIDs;
        }
        return result;
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return nil;
    }
}

#pragma mark - Sections

- (NSString *)createSectionNamed:(NSString *)name inList:(NSString *)listID error:(NSError **)error {
    @try {
        id list = [self rawList:listID error:error];
        if (!list) return nil;
        id request = [self newSaveRequest];
        id sections = Send(Send1(request, "updateList:", list), "sectionsContextChangeItem");
        id section = Send2(request, "addListSectionWithDisplayName:toListSectionContextChangeItem:", name, sections);
        if (!section) {
            if (error) *error = RKError(@"addListSectionWithDisplayName returned nil");
            return nil;
        }
        if (![self save:request error:error]) return nil;
        return UUIDOf(Send(section, "objectID"));
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return nil;
    }
}

- (BOOL)renameSection:(NSString *)sectionID inList:(NSString *)listID to:(NSString *)name error:(NSError **)error {
    @try {
        id list = [self rawList:listID error:error];
        id section = list ? [self rawSection:sectionID inList:list error:error] : nil;
        if (!section) return NO;
        id request = [self newSaveRequest];
        SendVoid1(Send1(request, "updateListSection:", section), "setDisplayName:", name);
        return [self save:request error:error];
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return NO;
    }
}

- (BOOL)deleteSection:(NSString *)sectionID inList:(NSString *)listID error:(NSError **)error {
    @try {
        id list = [self rawList:listID error:error];
        id section = list ? [self rawSection:sectionID inList:list error:error] : nil;
        if (!section) return NO;
        id request = [self newSaveRequest];
        SendVoid(Send1(request, "updateListSection:", section), "removeFromList");
        return [self save:request error:error];
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return NO;
    }
}

/// Puts a reminder into a section of `list`, or with a nil section takes it out of its section:
/// a membership in the list itself means "no section" (a nil group traps in ReminderKit, and an
/// obsolete membership in the old section is ignored).
- (BOOL)setSection:(NSString *)sectionID ofReminder:(id)change list:(id)list request:(id)request error:(NSError **)error {
    NSUUID *reminderUUID = Send(Send(change, "objectID"), "uuid");
    NSUUID *groupUUID = Send(Send(list, "objectID"), "uuid");
    if (sectionID) {
        id section = [self rawSection:sectionID inList:list error:error];
        if (!section) return NO;
        groupUUID = Send(Send(section, "objectID"), "uuid");
    }
    id sections = Send(Send1(request, "updateList:", list), "sectionsContextChangeItem");
    NSMutableDictionary *byMember = [NSMutableDictionary dictionary];
    NSDictionary *unsaved = Get(Get(sections, "unsavedMembershipsOfRemindersInSections"), "membershipByMemberIdentifier");
    if (unsaved) [byMember addEntriesFromDictionary:unsaved];
    byMember[reminderUUID] = ((id (*)(id, SEL, id, id, BOOL, id))objc_msgSend)(
        [NSClassFromString(@"REMMembership") alloc], sel_registerName("initWithMemberIdentifier:groupIdentifier:isObsolete:modifiedOn:"),
        reminderUUID, groupUUID, NO, [NSDate date]);
    SendVoid1(sections, "setUnsavedMembershipsOfRemindersInSections:",
              Send1([NSClassFromString(@"REMMemberships") alloc], "initWithMembershipByMemberIdentifier:", byMember));
    return YES;
}

#pragma mark - Reminders

static void ApplyRepeat(id change, NSDictionary *spec) {
    SendVoid(change, "removeAllRecurrenceRules");
    if (![spec isKindOfClass:[NSDictionary class]]) return;
    Class dayClass = NSClassFromString(@"REMRecurrenceDayOfWeek");
    NSMutableArray *days = nil;
    for (NSArray *day in spec[@"daysOfWeek"] ?: @[]) {
        days = days ?: [NSMutableArray array];
        [days addObject:((id (*)(id, SEL, long long, long long))objc_msgSend)(dayClass, sel_registerName("dayOfWeek:weekNumber:"),
                                                                             [day[0] longLongValue], [day[1] longLongValue])];
    }
    NSArray *monthDays = [spec[@"daysOfMonth"] count] ? spec[@"daysOfMonth"] : nil;
    NSArray *months = [spec[@"monthsOfYear"] count] ? spec[@"monthsOfYear"] : nil;
    Class endClass = NSClassFromString(@"REMRecurrenceEnd");
    id end = nil;
    if ([spec[@"endDate"] isKindOfClass:[NSDate class]]) end = Send1(endClass, "recurrenceEndWithEndDate:", spec[@"endDate"]);
    else if (spec[@"count"]) end = ((id (*)(id, SEL, unsigned long long))objc_msgSend)(endClass, sel_registerName("recurrenceEndWithOccurrenceCount:"), [spec[@"count"] unsignedLongLongValue]);
    ((id (*)(id, SEL, long long, long long, id, id, id, id, id, id, id))objc_msgSend)(
        change, sel_registerName("addRecurrenceRuleWithFrequency:interval:daysOfTheWeek:daysOfTheMonth:monthsOfTheYear:weeksOfTheYear:daysOfTheYear:setPositions:end:"),
        [spec[@"frequency"] longLongValue], [spec[@"interval"] longLongValue] ?: 1, days, monthDays, months, nil, nil, nil, end);
}

/// Applies a change dictionary to a reminder change item inside `request`. `list` is the
/// reminder's current list.
- (BOOL)apply:(NSDictionary *)changes to:(id)change list:(id)list request:(id)request error:(NSError **)error {
    if ([changes[@"title"] isKindOfClass:[NSString class]]) SendVoid1(change, "setTitleAsString:", changes[@"title"]);
    if ([changes[@"notes"] isKindOfClass:[NSString class]]) {
        NSString *notes = changes[@"notes"];
        SendVoid1(change, "setNotesAsString:", notes.length ? notes : nil);
    }
    if (changes[@"flagged"]) {
        ((void (*)(id, SEL, long long))objc_msgSend)(change, sel_registerName("setFlagged:"), [changes[@"flagged"] boolValue] ? 1 : 0);
    }
    if (changes[@"priority"]) {
        ((void (*)(id, SEL, unsigned long long))objc_msgSend)(change, sel_registerName("setPriority:"),
                                                              [changes[@"priority"] unsignedLongLongValue]);
    }
    id due = changes[@"due"];
    if ([due isKindOfClass:[NSDateComponents class]]) {
        // Replaces the date alarm the previous due date had.
        SendVoid(change, "removeAllAlarms");
        SendVoid1(change, "setDueDateComponentsWithAlarmsIfNeeded:", due);
    } else if (due == [NSNull null]) {
        SendVoid(change, "removeAllAlarms");
        SendVoid1(change, "setDueDateComponents:", nil);
    }
    if (changes[@"repeat"]) ApplyRepeat(change, changes[@"repeat"]);
    if (changes[@"urgent"]) {
        SendSetBool(Send(change, "urgentAlarmContext"), "setIsUrgentStateEnabledForCurrentUser:", [changes[@"urgent"] boolValue]);
    }
    if ([changes[@"tags"] isKindOfClass:[NSArray class]]) {
        id hashtags = Send(change, "hashtagContext");
        SendVoid(hashtags, "removeAllHashtags");
        for (NSString *name in changes[@"tags"]) {
            ((id (*)(id, SEL, long long, id))objc_msgSend)(hashtags, sel_registerName("addHashtagWithType:name:"), 0, name);
        }
    }
    id target = list;
    if ([changes[@"listId"] isKindOfClass:[NSString class]]) {
        target = [self rawList:changes[@"listId"] error:error];
        if (!target) return NO;
        SendVoid1(Send1(request, "updateList:", target), "addReminderChangeItem:", change);
    }
    id parentID = changes[@"parentId"];
    if ([parentID isKindOfClass:[NSString class]]) {
        id parent = [self rawReminder:parentID error:error];
        if (!parent) return NO;
        SendVoid1(Send(Send1(request, "updateReminder:", parent), "subtaskContext"), "addReminderChangeItem:", change);
    } else if (parentID == [NSNull null]) {
        // Re-adding the item to its list makes it a top-level reminder again.
        SendVoid1(Send1(request, "updateList:", target), "addReminderChangeItem:", change);
    }
    id sectionID = changes[@"sectionId"];
    if ([sectionID isKindOfClass:[NSString class]] || sectionID == [NSNull null]) {
        if (![self setSection:([sectionID isKindOfClass:[NSString class]] ? sectionID : nil) ofReminder:change list:target request:request error:error]) return NO;
    }
    id start = changes[@"start"];
    if ([start isKindOfClass:[NSDateComponents class]] || start == [NSNull null]) {
        SendVoid1(change, "setStartDateComponents:", start == [NSNull null] ? nil : start);
    }
    id early = changes[@"earlyAlerts"];
    if ([early isKindOfClass:[NSArray class]] || early == [NSNull null]) {
        id alerts = Send(change, "dueDateDeltaAlertContext");
        SendVoid(alerts, "removeAllFetchedDueDateDeltaAlerts");
        Class intervalClass = NSClassFromString(@"REMDueDateDeltaInterval");
        for (NSArray *alert in [early isKindOfClass:[NSArray class]] ? early : @[]) {
            id interval = ((id (*)(id, SEL, long long, long long))objc_msgSend)([intervalClass alloc], sel_registerName("initWithUnit:count:"),
                                                                              [alert[0] longLongValue], [alert[1] longLongValue]);
            Send1(alerts, "addDueDateDeltaAlertWithDueDateDelta:", interval);
        }
    }
    id location = changes[@"location"];
    if ([location isKindOfClass:[NSDictionary class]] || location == [NSNull null]) {
        // One place or vehicle trigger per reminder, as in Reminders.
        for (id alarm in [(NSArray *)Get(change, "alarms") ?: @[] copy]) {
            if (LocationInfo(Get(alarm, "trigger"))) SendVoid1(change, "removeAlarm:", alarm);
        }
        if ([location isKindOfClass:[NSDictionary class]]) {
            id trigger;
            if (location[@"vehicle"]) {
                trigger = ((id (*)(id, SEL, long long))objc_msgSend)([NSClassFromString(@"REMAlarmVehicleTrigger") alloc], sel_registerName("initWithEvent:"),
                                                                   [location[@"vehicle"] longLongValue]);
            } else {
                id place = Send1([NSClassFromString(@"REMStructuredLocation") alloc], "initWithTitle:", location[@"title"] ?: @"");
                ((void (*)(id, SEL, double))objc_msgSend)(place, sel_registerName("setLatitude:"), [location[@"latitude"] doubleValue]);
                ((void (*)(id, SEL, double))objc_msgSend)(place, sel_registerName("setLongitude:"), [location[@"longitude"] doubleValue]);
                ((void (*)(id, SEL, double))objc_msgSend)(place, sel_registerName("setRadius:"), [location[@"radius"] doubleValue]);
                if ([location[@"address"] isKindOfClass:[NSString class]]) SendVoid1(place, "setAddress:", location[@"address"]);
                trigger = ((id (*)(id, SEL, id, long long))objc_msgSend)([NSClassFromString(@"REMAlarmLocationTrigger") alloc],
                                                                       sel_registerName("initWithStructuredLocation:proximity:"), place,
                                                                       [location[@"proximity"] longLongValue]);
            }
            Send1(change, "addAlarmWithTrigger:", trigger);
        }
    }
    id contact = changes[@"contact"];
    if ([contact isKindOfClass:[NSDictionary class]]) {
        SendVoid1(change, "setContactHandles:", Send2([NSClassFromString(@"REMContactRepresentation") alloc], "initWithPhones:emails:",
                                                      contact[@"phones"] ?: @[], contact[@"emails"] ?: @[]));
    } else if (contact == [NSNull null]) {
        SendVoid1(change, "setContactHandles:", nil);
    }
    id attachments = nil;
    id url = changes[@"url"];
    if ([url isKindOfClass:[NSString class]] || url == [NSNull null]) {
        attachments = Send(change, "attachmentContext");
        if (url == [NSNull null]) SendVoid(attachments, "removeURLAttachments");
        else Send1(attachments, "setURLAttachmentWithURL:", [NSURL URLWithString:url]);
    }
    for (NSString *imageID in [changes[@"removeImages"] isKindOfClass:[NSArray class]] ? changes[@"removeImages"] : @[]) {
        attachments = attachments ?: Send(change, "attachmentContext");
        for (id image in [(NSArray *)Get(attachments, "imageAttachments") ?: @[] copy]) {
            if ([UUIDOf(Send(image, "objectID")) caseInsensitiveCompare:imageID] == NSOrderedSame) SendVoid1(attachments, "removeAttachment:", image);
        }
    }
    for (NSDictionary *image in [changes[@"addImages"] isKindOfClass:[NSArray class]] ? changes[@"addImages"] : @[]) {
        attachments = attachments ?: Send(change, "attachmentContext");
        NSError *imageError = nil;
        id added = ((id (*)(id, SEL, id, unsigned long long, unsigned long long, NSError **))objc_msgSend)(
            attachments, sel_registerName("addImageAttachmentWithURL:width:height:error:"), [NSURL fileURLWithPath:image[@"path"]],
            [image[@"width"] unsignedLongLongValue], [image[@"height"] unsignedLongLongValue], &imageError);
        if (!added) {
            if (error) *error = imageError ?: RKError([NSString stringWithFormat:@"Could not attach %@", image[@"path"]]);
            return NO;
        }
    }
    id assignee = changes[@"assigneeId"];
    if ([assignee isKindOfClass:[NSString class]] || assignee == [NSNull null]) {
        id assignments = Send(change, "assignmentContext");
        SendVoid(assignments, "removeAllAssignments");
        if ([assignee isKindOfClass:[NSString class]]) {
            id person = [self rawSharee:assignee inList:target];
            NSString *me = Get(Send(target, "storage"), "currentUserShareParticipantID");
            id originator = me ? [self rawSharee:me inList:target] : nil;
            if (!person || !originator) {
                if (error) *error = RKError(@"That person is not on this shared list");
                return NO;
            }
            // Status 0 is "assigned".
            ((id (*)(id, SEL, id, id, long long))objc_msgSend)(assignments, sel_registerName("addAssignmentWithAssignee:originator:status:"), person, originator, 0);
        }
    }
    NSDictionary *position = changes[@"position"];
    if ([position isKindOfClass:[NSDictionary class]]) {
        BOOL after = position[@"after"] != nil;
        id neighbor = [self rawReminder:(after ? position[@"after"] : position[@"before"]) error:error];
        if (!neighbor) return NO;
        id neighborChange = Send1(request, "updateReminder:", neighbor);
        const char *insert = after ? "insertReminderChangeItem:afterReminderChangeItem:" : "insertReminderChangeItem:beforeReminderChangeItem:";
        id parent = UUIDOf(Get(neighbor, "parentReminderID"));
        if (parent) {
            id parentReminder = [self rawReminder:parent error:error];
            if (!parentReminder) return NO;
            SendVoid2(Send(Send1(request, "updateReminder:", parentReminder), "subtaskContext"), insert, change, neighborChange);
        } else {
            SendVoid2(Send1(request, "updateList:", target), insert, change, neighborChange);
        }
    }
    if (changes[@"completed"]) {
        // Set last, so a repeating reminder moves on from its final due date and rule.
        if ([changes[@"completeRecurring"] boolValue]) SendSetBool(request, "setCloneCompletedRecurrentRemindersAtSave:", YES);
        SendSetBool(change, "setCompleted:", [changes[@"completed"] boolValue]);
    }
    return YES;
}

- (NSString *)addReminderToList:(NSString *)listID title:(NSString *)title changes:(NSDictionary *)changes error:(NSError **)error {
    @try {
        id list = [self rawList:listID error:error];
        if (!list) return nil;
        id request = [self newSaveRequest];
        id change = Send2(request, "addReminderWithTitle:toListChangeItem:", title, Send1(request, "updateList:", list));
        if (!change) {
            if (error) *error = RKError(@"addReminderWithTitle returned nil");
            return nil;
        }
        NSMutableDictionary *rest = [changes mutableCopy];
        [rest removeObjectForKey:@"listId"];
        if (![self apply:rest to:change list:list request:request error:error]) return nil;
        if (![self save:request error:error]) return nil;
        return UUIDOf(Send(change, "objectID"));
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return nil;
    }
}

- (BOOL)updateReminder:(NSString *)reminderID changes:(NSDictionary *)changes error:(NSError **)error {
    @try {
        // Replacing early reminders needs the current ones loaded, so they can be removed.
        id reminder = changes[@"earlyAlerts"] ? [self rawReminderWithAlerts:reminderID error:error] : [self rawReminder:reminderID error:error];
        if (!reminder) return NO;
        id list = [self rawList:UUIDOf(Send(reminder, "listID")) error:error];
        if (!list) return NO;
        id request = [self newSaveRequest];
        id change = Send1(request, "updateReminder:", reminder);
        if (![self apply:changes to:change list:list request:request error:error]) return NO;
        return [self save:request error:error];
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return NO;
    }
}

- (BOOL)deleteReminders:(NSArray<NSString *> *)reminderIDs error:(NSError **)error {
    @try {
        id request = [self newSaveRequest];
        for (NSString *reminderID in reminderIDs) {
            id reminder = [self rawReminder:reminderID error:error];
            if (!reminder) return NO;
            SendVoid(Send1(request, "updateReminder:", reminder), "removeFromList");
        }
        return [self save:request error:error];
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return NO;
    }
}

#pragma mark - Section order, templates, tags

- (BOOL)moveSection:(NSString *)sectionID inList:(NSString *)listID relativeTo:(NSString *)otherID after:(BOOL)after error:(NSError **)error {
    @try {
        id list = [self rawList:listID error:error];
        if (!list) return NO;
        NSMutableArray *order = [NSMutableArray array];
        id moving = nil;
        for (id section in [self rawSectionsInList:list error:error]) {
            if ([UUIDOf(Send(section, "objectID")) caseInsensitiveCompare:sectionID] == NSOrderedSame) moving = Send(section, "objectID");
            else [order addObject:Send(section, "objectID")];
        }
        NSUInteger anchor = [order indexOfObjectPassingTest:^BOOL(id objectID, NSUInteger index, BOOL *stop) {
            return [UUIDOf(objectID) caseInsensitiveCompare:otherID] == NSOrderedSame;
        }];
        if (!moving || anchor == NSNotFound) {
            if (error) *error = RKError(@"Both sections must be in the list");
            return NO;
        }
        [order insertObject:moving atIndex:after ? anchor + 1 : anchor];
        id request = [self newSaveRequest];
        id sections = Send(Send1(request, "updateList:", list), "sectionsContextChangeItem");
        SendVoid1(sections, "setUnsavedSectionIDsOrdering:", order);
        SendSetBool(sections, "setShouldUpdateSectionsOrdering:", YES);
        return [self save:request error:error];
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return NO;
    }
}

- (NSArray *)rawTemplatesWithError:(NSError **)error {
    id account = [self defaultAccountWithError:error];
    if (!account) return nil;
    id view = Send1([NSClassFromString(@"REMTemplatesDataView") alloc], "initWithStore:", _store);
    return Send1WithError(view, "fetchTemplatesInAccount:error:", account, error);
}

- (id)rawTemplate:(NSString *)templateID error:(NSError **)error {
    for (id template in [self rawTemplatesWithError:error] ?: @[]) {
        if ([UUIDOf(Send(template, "objectID")) caseInsensitiveCompare:templateID] == NSOrderedSame) return template;
    }
    if (error && !*error) *error = RKError([NSString stringWithFormat:@"No template with id %@", templateID]);
    return nil;
}

- (NSArray *)templatesWithError:(NSError **)error {
    @try {
        NSArray *templates = [self rawTemplatesWithError:error];
        if (!templates) return nil;
        NSMutableArray *result = [NSMutableArray array];
        for (id template in templates) {
            NSMutableDictionary *item = [@{@"id": UUIDOf(Send(template, "objectID")) ?: @"", @"name": Get(template, "name") ?: @""} mutableCopy];
            NSDictionary *color = ColorInfo(Get(template, "color"));
            if (color) item[@"color"] = color;
            NSString *icon = Get(template, "badgeEmblem");
            if (icon.length) item[@"icon"] = icon;
            [result addObject:item];
        }
        return result;
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return nil;
    }
}

- (NSString *)createTemplateNamed:(NSString *)name fromList:(NSString *)listID includeCompleted:(BOOL)includeCompleted error:(NSError **)error {
    @try {
        id list = [self rawList:listID error:error];
        id account = list ? [self defaultAccountWithError:error] : nil;
        if (!account) return nil;
        id configuration = ((id (*)(id, SEL, id, BOOL))objc_msgSend)([NSClassFromString(@"REMTemplateConfiguration") alloc],
                                                                   sel_registerName("initWithSourceListID:shouldSaveCompleted:"), Send(list, "objectID"), includeCompleted);
        id request = [self newSaveRequest];
        id template = Send3(request, "addTemplateWithName:configuration:toAccountChangeItem:", name, configuration, Send1(request, "updateAccount:", account));
        if (!template) {
            if (error) *error = RKError(@"addTemplateWithName returned nil");
            return nil;
        }
        if (![self save:request error:error]) return nil;
        return UUIDOf(Send(template, "objectID"));
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return nil;
    }
}

- (NSString *)createListFromTemplate:(NSString *)templateID name:(NSString *)name error:(NSError **)error {
    @try {
        id template = [self rawTemplate:templateID error:error];
        id account = template ? [self defaultAccountWithError:error] : nil;
        if (!account) return nil;
        id request = [self newSaveRequest];
        id list = Send2(request, "addListUsingTemplate:toAccountChangeItem:", template, Send1(request, "updateAccount:", account));
        if (!list) {
            if (error) *error = RKError(@"addListUsingTemplate returned nil");
            return nil;
        }
        if (name.length) SendVoid1(Send(list, "storage"), "setName:", name);
        if (![self save:request error:error]) return nil;
        return UUIDOf(Send(list, "objectID"));
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return nil;
    }
}

- (BOOL)deleteTemplate:(NSString *)templateID error:(NSError **)error {
    @try {
        id template = [self rawTemplate:templateID error:error];
        if (!template) return NO;
        id request = [self newSaveRequest];
        SendVoid(Send1(request, "updateTemplate:", template), "removeFromParentAccount");
        return [self save:request error:error];
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return NO;
    }
}

- (NSNumber *)replaceTag:(NSString *)tag with:(NSString *)replacement error:(NSError **)error {
    @try {
        NSArray *lists = [self rawListsWithError:error];
        if (!lists) return nil;
        id request = [self newSaveRequest];
        NSInteger changed = 0;
        for (id list in lists) {
            NSArray *reminders = [self rawRemindersInList:list error:error];
            if (!reminders) return nil;
            for (id reminder in reminders) {
                NSMutableArray *matching = [NSMutableArray array];
                BOOL hasReplacement = NO;
                for (id hashtag in (NSSet *)Get(reminder, "hashtags") ?: [NSSet set]) {
                    NSString *name = Get(hashtag, "name");
                    if ([name caseInsensitiveCompare:tag] == NSOrderedSame) [matching addObject:hashtag];
                    else if (replacement && [name caseInsensitiveCompare:replacement] == NSOrderedSame) hasReplacement = YES;
                }
                if (!matching.count) continue;
                id hashtags = Send(Send1(request, "updateReminder:", reminder), "hashtagContext");
                for (id hashtag in matching) SendVoid1(hashtags, "removeHashtag:", hashtag);
                if (replacement && !hasReplacement) {
                    ((id (*)(id, SEL, long long, id))objc_msgSend)(hashtags, sel_registerName("addHashtagWithType:name:"), 0, replacement);
                }
                changed++;
            }
        }
        if (changed && ![self save:request error:error]) return nil;
        return @(changed);
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return nil;
    }
}

#pragma mark - Recently Deleted

- (NSDictionary *)deletedReminders:(NSArray<NSString *> *)reminderIDs error:(NSError **)error {
    @try {
        NSMutableArray *objectIDs = [NSMutableArray array];
        for (NSString *reminderID in reminderIDs) {
            id objectID = [self reminderObjectID:reminderID];
            if (objectID) [objectIDs addObject:objectID];
        }
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        if (!objectIDs.count) return result;
        // Soft-deleted reminders are "concealed": only this fetch option returns them, and their
        // list is gone.
        id options = Send(NSClassFromString(@"REMReminderFetchOptions"), "fetchOptionsIncludingConcealed");
        NSDictionary *found = ((id (*)(id, SEL, id, id, NSError **))objc_msgSend)(
            _store, sel_registerName("fetchRemindersWithObjectIDs:fetchOptions:error:"), objectIDs, options, error);
        if (!found) return nil;
        for (id reminder in found.allValues) {
            if (Get(reminder, "listID")) continue;
            NSMutableDictionary *item = [@{@"title": Send(reminder, "titleAsString") ?: @"", @"completed": @(SendBool(reminder, "isCompleted"))} mutableCopy];
            NSString *parent = UUIDOf(Get(reminder, "parentReminderID"));
            if (parent) item[@"parentId"] = parent;
            result[UUIDOf(Send(reminder, "objectID"))] = item;
        }
        return result;
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return nil;
    }
}

- (BOOL)restoreReminders:(NSArray<NSString *> *)reminderIDs toList:(NSString *)listID error:(NSError **)error {
    @try {
        id list = [self rawList:listID error:error];
        if (!list) return NO;
        NSMutableArray *objectIDs = [NSMutableArray array];
        for (NSString *reminderID in reminderIDs) {
            id objectID = [self reminderObjectID:reminderID];
            if (objectID) [objectIDs addObject:objectID];
        }
        id request = [self newSaveRequest];
        SendVoid1(Send1(request, "updateList:", list), "undeleteRemindersWithoutUndoWithIDs:", objectIDs);
        return [self save:request error:error];
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return NO;
    }
}

@end
