#import "ContactsShim.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Every private call goes through a typed objc_msgSend (on arm64 a variadic cast passes arguments
// in the wrong registers) after a respondsToSelector: check. Selectors and argument types were
// read from the runtime (method type encodings) on macOS 27.2.1.

static NSError *CSError(NSString *message) {
    return [NSError errorWithDomain:@"ContactsShim" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL Responds(id target, SEL selector, NSError **error) {
    if ([target respondsToSelector:selector]) return YES;
    if (error) *error = CSError([NSString stringWithFormat:@"This version of macOS has no %@ on %@", NSStringFromSelector(selector), NSStringFromClass([target class])]);
    return NO;
}

static void SetObject(id target, SEL selector, id value) {
    ((void (*)(id, SEL, id))objc_msgSend)(target, selector, value);
}

static id Value(id object, NSString *key) {
    if (!object) return nil;
    @try { return [object valueForKey:key]; } @catch (NSException *exception) { return nil; }
}

static NSString *IdentifierOf(id contact) {
    id identifier = Value(contact, @"identifier");
    return [identifier isKindOfClass:[NSString class]] ? identifier : nil;
}

// Private methods declared so ARC applies their ownership rules (init consumes self and returns +1;
// new… returns +1); every call site checks that the method is there first.
@interface NSObject (CSPrivateInitializers)
- (nullable instancetype)initWithSound:(nullable NSString *)sound vibration:(nullable NSString *)vibration ignoreMute:(BOOL)ignoreMute;
@end

@interface CNContact (CSPrivate)
+ (nullable instancetype)newContactWithPropertyKeys:(id)keys withValuesFromContact:(CNContact *)contact;
@end

@implementation CSStore

+ (void)allowDowntimeChangesInRequest:(CNSaveRequest *)request {
    SEL selector = NSSelectorFromString(@"setIgnoresGuardianRestrictions:");
    if ([request respondsToSelector:selector]) ((void (*)(id, SEL, BOOL))objc_msgSend)(request, selector, YES);
}

+ (BOOL)isGuardianRestrictedContainer:(CNContainer *)container {
    SEL selector = NSSelectorFromString(@"isGuardianRestricted");
    if (![container respondsToSelector:selector]) return YES;
    return ((BOOL (*)(id, SEL))objc_msgSend)(container, selector);
}

+ (BOOL)linkContact:(CNMutableContact *)contact toContact:(CNMutableContact *)other request:(CNSaveRequest *)request error:(NSError **)error {
    SEL selector = NSSelectorFromString(@"linkContact:toContact:");
    if (!Responds(request, selector, error)) return NO;
    ((void (*)(id, SEL, id, id))objc_msgSend)(request, selector, contact, other);
    return YES;
}

+ (BOOL)unlinkContact:(CNContact *)contact request:(CNSaveRequest *)request error:(NSError **)error {
    SEL selector = NSSelectorFromString(@"unlinkContact:");
    if (!Responds(request, selector, error)) return NO;
    SetObject(request, selector, contact);
    return YES;
}

+ (BOOL)setMeCardIdentifier:(NSString *)identifier request:(CNSaveRequest *)request error:(NSError **)error {
    SEL selector = NSSelectorFromString(@"setMeCardIdentifier:");
    if (!Responds(request, selector, error)) return NO;
    SetObject(request, selector, identifier);
    return YES;
}

static BOOL SetBool(CNMutableContact *contact, NSString *name, BOOL value, NSError **error) {
    SEL selector = NSSelectorFromString(name);
    if (!Responds(contact, selector, error)) return NO;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(contact, selector, value);
    return YES;
}

+ (BOOL)setPreferredForName:(BOOL)value contact:(CNMutableContact *)contact error:(NSError **)error {
    return SetBool(contact, @"setPreferredForName:", value, error);
}

+ (BOOL)setPreferredForImage:(BOOL)value contact:(CNMutableContact *)contact error:(NSError **)error {
    return SetBool(contact, @"setPreferredForImage:", value, error);
}

+ (BOOL)setCropRect:(CGRect)rect contact:(CNMutableContact *)contact error:(NSError **)error {
    SEL selector = NSSelectorFromString(@"setCropRect:");
    if (!Responds(contact, selector, error)) return NO;
    ((void (*)(id, SEL, CGRect))objc_msgSend)(contact, selector, rect);
    return YES;
}

+ (BOOL)clearThumbnailOfContact:(CNMutableContact *)contact error:(NSError **)error {
    SEL selector = NSSelectorFromString(@"setThumbnailImageData:");
    if (!Responds(contact, selector, error)) return NO;
    SetObject(contact, selector, nil);
    return YES;
}

+ (BOOL)setDisplayNameOrder:(NSInteger)order contact:(CNMutableContact *)contact error:(NSError **)error {
    SEL selector = NSSelectorFromString(@"setDisplayNameOrder:");
    if (!Responds(contact, selector, error)) return NO;
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(contact, selector, order);
    return YES;
}

+ (BOOL)setDowntimeAllowed:(BOOL)allowed contact:(CNMutableContact *)contact error:(NSError **)error {
    SEL selector = NSSelectorFromString(@"setDowntimeWhitelist:");
    if (!Responds(contact, selector, error)) return NO;
    SetObject(contact, selector, allowed ? @"true" : nil);
    return YES;
}

+ (BOOL)setAlertForCalls:(BOOL)calls sound:(NSString *)sound vibration:(NSString *)vibration ignoreMute:(BOOL)ignoreMute
                   clear:(BOOL)clear contact:(CNMutableContact *)contact error:(NSError **)error {
    SEL setter = NSSelectorFromString(calls ? @"setCallAlert:" : @"setTextAlert:");
    if (!Responds(contact, setter, error)) return NO;
    if (clear) {
        SetObject(contact, setter, nil);
        return YES;
    }
    Class alertClass = NSClassFromString(@"CNActivityAlert");
    SEL make = NSSelectorFromString(@"initWithSound:vibration:ignoreMute:");
    if (!alertClass || ![alertClass instancesRespondToSelector:make]) {
        if (error) *error = CSError(@"This version of macOS has no CNActivityAlert");
        return NO;
    }
    id alert = [[alertClass alloc] initWithSound:sound vibration:vibration ignoreMute:ignoreMute];
    if (!alert) {
        if (error) *error = CSError(@"Contacts did not make the alert");
        return NO;
    }
    SetObject(contact, setter, alert);
    return YES;
}

+ (NSDictionary<NSString *, id> *)alertForCalls:(BOOL)calls contact:(CNContact *)contact {
    NSString *key = calls ? @"callAlert" : @"textAlert";
    if (![contact isKeyAvailable:key]) return nil;
    id alert = nil;
    @try { alert = [contact valueForKey:key]; } @catch (NSException *exception) { return nil; }
    if (!alert) return nil;
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *name in @[@"sound", @"vibration"]) {
        if ([alert respondsToSelector:NSSelectorFromString(name)]) {
            id value = [alert valueForKey:name];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) result[name] = value;
        }
    }
    if ([alert respondsToSelector:NSSelectorFromString(@"ignoreMute")]) {
        result[@"ignore_mute"] = @(((BOOL (*)(id, SEL))objc_msgSend)(alert, NSSelectorFromString(@"ignoreMute")));
    }
    return result.count ? result : nil;
}

+ (CNMutableContact *)restorableCopyOfContact:(CNContact *)contact error:(NSError **)error {
    CNMutableContact *copy = [contact mutableCopy];
    SEL selector = NSSelectorFromString(@"setSnapshot:");
    if (!Responds(copy, selector, error)) return nil;
    SetObject(copy, selector, nil);
    return copy;
}

+ (CNMutableContact *)copyOmittingNote:(CNContact *)contact error:(NSError **)error {
    SEL make = NSSelectorFromString(@"newContactWithPropertyKeys:withValuesFromContact:");
    if (![CNContact respondsToSelector:make] || ![contact respondsToSelector:NSSelectorFromString(@"availableKeys")]) {
        if (error) *error = CSError(@"This version of macOS cannot copy a parsed vCard without its note");
        return nil;
    }
    NSMutableSet *keys = [NSMutableSet set];
    id available = [contact valueForKey:@"availableKeys"];
    if ([available isKindOfClass:[NSSet class]]) [keys unionSet:available];
    else if ([available isKindOfClass:[NSArray class]]) [keys addObjectsFromArray:available];
    else if ([available respondsToSelector:NSSelectorFromString(@"allKeys")]) [keys addObjectsFromArray:[available valueForKey:@"allKeys"]];
    [keys removeObject:CNContactNoteKey];
    [keys removeObject:@"addressingGrammars"];
    [keys removeObject:CNContactIdentifierKey];
    CNContact *copy = nil;
    @try {
        copy = [CNContact newContactWithPropertyKeys:keys withValuesFromContact:contact];
    } @catch (NSException *exception) {
        copy = nil;
    }
    if (!copy) {
        if (error) *error = CSError(@"Contacts could not copy the parsed vCard without its note");
        return nil;
    }
    return [copy mutableCopy];
}

+ (CNContact *)copyOfContact:(CNContact *)contact withNote:(NSString *)note error:(NSError **)error {
    SEL make = NSSelectorFromString(@"makeContactAndMergeValuesFromAvailableKeysInContact:");
    if (![CNContact respondsToSelector:make]) {
        if (error) *error = CSError(@"This version of macOS cannot add a note to an exported card");
        return nil;
    }
    CNMutableContact *copy = nil;
    @try {
        CNContact *merged = ((id (*)(id, SEL, id))objc_msgSend)([CNContact class], make, contact);
        copy = [merged mutableCopy];
        copy.note = note;
    } @catch (NSException *exception) {
        if (error) *error = CSError(@"Contacts refused to add the note to the exported card");
        return nil;
    }
    return copy;
}

+ (NSPredicate *)fullTextPredicateForText:(NSString *)text {
    SEL selector = NSSelectorFromString(@"predicateForContactsMatchingFullTextSearch:containerIdentifiers:groupIdentifiers:");
    if (![CNContact respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, id, id, id))objc_msgSend)([CNContact class], selector, text, nil, nil);
}

+ (NSPredicate *)meContactsPredicate {
    SEL selector = NSSelectorFromString(@"predicateForMeContact");
    if (![CNContact respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)([CNContact class], selector);
}

+ (NSPredicate *)groupsWithMemberContact:(CNContact *)contact parents:(BOOL)parents {
    SEL selector = NSSelectorFromString(@"predicateForGroupsWithMemberContact:includeAllParentGroups:");
    if (![CNGroup respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, id, BOOL))objc_msgSend)([CNGroup class], selector, contact, parents);
}

+ (NSPredicate *)groupsWithMemberGroup:(CNGroup *)group parents:(BOOL)parents {
    SEL selector = NSSelectorFromString(@"predicateForGroupsWithMemberGroup:includeAllParentGroups:");
    if (![CNGroup respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, id, BOOL))objc_msgSend)([CNGroup class], selector, group, parents);
}

+ (NSDictionary<NSString *, id> *)nameSettings {
    Class defaultsClass = NSClassFromString(@"CNFoundationUserDefaults");
    if (![defaultsClass respondsToSelector:NSSelectorFromString(@"sharedDefaults")]) return nil;
    id defaults = ((id (*)(id, SEL))objc_msgSend)(defaultsClass, NSSelectorFromString(@"sharedDefaults"));
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    NSUInteger (*unsignedCall)(id, SEL) = (NSUInteger (*)(id, SEL))objc_msgSend;
    BOOL (*boolCall)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
    if ([defaults respondsToSelector:NSSelectorFromString(@"sortOrder")]) settings[@"sort_by_first_name"] = @(unsignedCall(defaults, NSSelectorFromString(@"sortOrder")) == 0);
    if ([defaults respondsToSelector:NSSelectorFromString(@"nameOrder")]) settings[@"family_name_first"] = @(unsignedCall(defaults, NSSelectorFromString(@"nameOrder")) == 1);
    if ([defaults respondsToSelector:NSSelectorFromString(@"isShortNameFormatEnabled")]) settings[@"short_names"] = @(boolCall(defaults, NSSelectorFromString(@"isShortNameFormatEnabled")));
    if ([defaults respondsToSelector:NSSelectorFromString(@"shortNameFormat")]) settings[@"short_name_format"] = @(unsignedCall(defaults, NSSelectorFromString(@"shortNameFormat")));
    if ([defaults respondsToSelector:NSSelectorFromString(@"preferNickname")]) settings[@"prefer_nicknames"] = @(boolCall(defaults, NSSelectorFromString(@"preferNickname")));
    if ([defaults respondsToSelector:NSSelectorFromString(@"countryCode")]) {
        id code = ((id (*)(id, SEL))objc_msgSend)(defaults, NSSelectorFromString(@"countryCode"));
        if ([code isKindOfClass:[NSString class]]) settings[@"country_code"] = code;
    }
    return settings;
}

// vCard writing options live in the private vCard.framework (CNVCardWritingOptions).
+ (NSData *)vCardForContacts:(NSArray<CNContact *> *)contacts version21:(BOOL)version21 photos:(BOOL)photos notes:(BOOL)notes error:(NSError **)error {
    dlopen("/System/Library/PrivateFrameworks/vCard.framework/vCard", RTLD_NOW);
    Class optionsClass = NSClassFromString(@"CNVCardWritingOptions");
    SEL write = NSSelectorFromString(@"dataWithContacts:options:error:");
    @try {
        if (!optionsClass || ![CNContactVCardSerialization respondsToSelector:write]) {
            return [CNContactVCardSerialization dataWithContacts:contacts error:error];
        }
        id options = [optionsClass new];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(options, NSSelectorFromString(@"setOutputVersion:"), version21 ? 1 : 2);
        ((void (*)(id, SEL, BOOL))objc_msgSend)(options, NSSelectorFromString(@"setIncludePhotos:"), photos);
        ((void (*)(id, SEL, BOOL))objc_msgSend)(options, NSSelectorFromString(@"setIncludeNotes:"), notes);
        if (version21) {
            Class encoding = NSClassFromString(@"CNVCardEncoding");
            id utf8 = [encoding respondsToSelector:NSSelectorFromString(@"utf8Encoding")] ? [encoding valueForKey:@"utf8Encoding"] : nil;
            if (utf8) SetObject(options, NSSelectorFromString(@"setAvailableEncodings:"), @[utf8]);
        }
        return ((id (*)(id, SEL, id, id, NSError **))objc_msgSend)([CNContactVCardSerialization class], write, contacts, options, error);
    } @catch (NSException *exception) {
        if (error) *error = CSError([NSString stringWithFormat:@"Contacts could not write the vCard: %@", exception.reason]);
        return nil;
    }
}

+ (NSData *)currentHistoryTokenOfStore:(CNContactStore *)store {
    return store.currentHistoryToken;
}

+ (NSDictionary<NSString *, id> *)changesInStore:(CNContactStore *)store since:(NSData *)token excludingAuthor:(NSString *)author error:(NSError **)error {
    CNChangeHistoryFetchRequest *request = [CNChangeHistoryFetchRequest new];
    request.startingToken = token;
    request.includeGroupChanges = YES;
    request.shouldUnifyResults = NO;
    if (author) request.excludedTransactionAuthors = @[author];
    CNFetchResult<NSEnumerator<CNChangeHistoryEvent *> *> *result = nil;
    @try {
        result = [store enumeratorForChangeHistoryFetchRequest:request error:error];
    } @catch (NSException *exception) {
        if (error) *error = CSError([NSString stringWithFormat:@"Contacts could not read its change history: %@", exception.reason]);
        return nil;
    }
    if (!result) return nil;
    NSMutableArray *events = [NSMutableArray array];
    for (CNChangeHistoryEvent *event in result.value) {
        NSString *kind = nil;
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        if ([event isKindOfClass:[CNChangeHistoryDropEverythingEvent class]]) kind = @"everything";
        else if ([event isKindOfClass:[CNChangeHistoryAddContactEvent class]]) { kind = @"added"; row[@"contact"] = ((CNChangeHistoryAddContactEvent *)event).contact.identifier; }
        else if ([event isKindOfClass:[CNChangeHistoryUpdateContactEvent class]]) { kind = @"updated"; row[@"contact"] = ((CNChangeHistoryUpdateContactEvent *)event).contact.identifier; }
        else if ([event isKindOfClass:[CNChangeHistoryDeleteContactEvent class]]) { kind = @"deleted"; row[@"contact"] = ((CNChangeHistoryDeleteContactEvent *)event).contactIdentifier; }
        else if ([event isKindOfClass:[CNChangeHistoryAddGroupEvent class]]) { kind = @"group_added"; row[@"group"] = ((CNChangeHistoryAddGroupEvent *)event).group.identifier; }
        else if ([event isKindOfClass:[CNChangeHistoryUpdateGroupEvent class]]) { kind = @"group_updated"; row[@"group"] = ((CNChangeHistoryUpdateGroupEvent *)event).group.identifier; }
        else if ([event isKindOfClass:[CNChangeHistoryDeleteGroupEvent class]]) { kind = @"group_deleted"; row[@"group"] = ((CNChangeHistoryDeleteGroupEvent *)event).groupIdentifier; }
        else if ([event isKindOfClass:[CNChangeHistoryAddMemberToGroupEvent class]]) {
            kind = @"member_added"; row[@"contact"] = ((CNChangeHistoryAddMemberToGroupEvent *)event).member.identifier; row[@"group"] = ((CNChangeHistoryAddMemberToGroupEvent *)event).group.identifier;
        } else if ([event isKindOfClass:[CNChangeHistoryRemoveMemberFromGroupEvent class]]) {
            kind = @"member_removed"; row[@"contact"] = ((CNChangeHistoryRemoveMemberFromGroupEvent *)event).member.identifier; row[@"group"] = ((CNChangeHistoryRemoveMemberFromGroupEvent *)event).group.identifier;
        } else if ([event isKindOfClass:[CNChangeHistoryAddSubgroupToGroupEvent class]]) {
            kind = @"subgroup_added"; row[@"group"] = ((CNChangeHistoryAddSubgroupToGroupEvent *)event).group.identifier; row[@"subgroup"] = ((CNChangeHistoryAddSubgroupToGroupEvent *)event).subgroup.identifier;
        } else if ([event isKindOfClass:[CNChangeHistoryRemoveSubgroupFromGroupEvent class]]) {
            kind = @"subgroup_removed"; row[@"group"] = ((CNChangeHistoryRemoveSubgroupFromGroupEvent *)event).group.identifier; row[@"subgroup"] = ((CNChangeHistoryRemoveSubgroupFromGroupEvent *)event).subgroup.identifier;
        } else if ([event isKindOfClass:NSClassFromString(@"CNChangeHistoryLinkContactsEvent")]) {
            kind = @"linked"; row[@"contact"] = IdentifierOf(Value(event, @"fromContact")); row[@"other"] = IdentifierOf(Value(event, @"toContact"));
        } else if ([event isKindOfClass:NSClassFromString(@"CNChangeHistoryUnlinkContactEvent")]) {
            kind = @"unlinked"; row[@"contact"] = IdentifierOf(Value(event, @"contact"));
        } else if ([event isKindOfClass:NSClassFromString(@"CNChangeHistoryPreferredContactForNameEvent")]
                   || [event isKindOfClass:NSClassFromString(@"CNChangeHistoryPreferredContactForImageEvent")]) {
            kind = @"preferred"; row[@"contact"] = IdentifierOf(Value(event, @"preferredContact"));
        } else if ([event isKindOfClass:NSClassFromString(@"CNChangeHistoryDifferentMeCardEvent")]) {
            kind = @"me"; id identifier = Value(event, @"contactIdentifier");
            if ([identifier isKindOfClass:[NSString class]]) row[@"contact"] = identifier;
        } else {
            kind = NSStringFromClass([event class]);
            for (NSString *key in @[@"contactIdentifier", @"identifier"]) {
                id identifier = Value(event, key);
                if ([identifier isKindOfClass:[NSString class]]) { row[@"contact"] = identifier; break; }
            }
        }
        row[@"kind"] = kind;
        [events addObject:row];
    }
    NSMutableDictionary *answer = [NSMutableDictionary dictionaryWithObject:events forKey:@"events"];
    if (result.currentHistoryToken) answer[@"token"] = result.currentHistoryToken;
    return answer;
}

@end
