#import "ContactsShim.h"
#import <AddressBook/AddressBook.h>
#import <dlfcn.h>
#import <objc/message.h>

// AddressBook.framework is deprecated but is what Contacts.app itself runs on (its ABBook…Command
// classes); its private parts used here were read from the runtime and Contacts.app's own calls.

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static NSError *ABError(NSString *message) {
    return [NSError errorWithDomain:@"ContactsShim" code:2 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static id Send(id target, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![target respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

/// An integer property of a private object, or NSNotFound when this version of macOS has no such method.
static NSInteger SendInteger(id target, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![target respondsToSelector:selector]) return NSNotFound;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(target, selector);
}

static NSError *ExceptionError(NSException *exception) {
    return ABError([NSString stringWithFormat:@"AddressBook raised %@: %@", exception.name, exception.reason ?: @"no reason"]);
}

// Private initializer declared so ARC applies the init rules (it consumes self and returns +1).
@interface NSObject (CSSmartGroupInit)
- (nullable instancetype)initWithAddressBook:(ABAddressBook *)book account:(id)account;
@end

/// A fresh address book for each call, so it sees what Contacts.framework saved since.
static ABAddressBook *Book(NSError **error) {
    ABAddressBook *book = [ABAddressBook addressBook];
    if (!book && error) *error = ABError(@"AddressBook could not open the contacts database");
    return book;
}

static BOOL Save(ABAddressBook *book, NSError **error) {
    NSError *saveError = nil;
    if ([book saveAndReturnError:&saveError]) return YES;
    if (error) *error = saveError ?: ABError(@"AddressBook could not save");
    return NO;
}

static Class SmartGroupClass(void) { return NSClassFromString(@"ABSmartGroup"); }

#pragma mark Criteria

// Contacts' smart-list editor's comparisons (ABSearchComparison) by the names the tools use.
static NSDictionary<NSString *, NSNumber *> *Comparisons(void) {
    return @{@"contains": @(kABContainsSubStringCaseInsensitive), @"not_contains": @(kABDoesNotContainSubStringCaseInsensitive),
             @"is": @(kABEqualCaseInsensitive), @"is_not": @(kABNotEqualCaseInsensitive),
             @"starts_with": @(kABPrefixMatchCaseInsensitive), @"ends_with": @(kABSuffixMatchCaseInsensitive),
             @"next_days": @(kABWithinIntervalFromTodayYearless), @"within_days": @(kABWithinIntervalAroundTodayYearless),
             @"not_within_days": @(kABNotWithinIntervalAroundTodayYearless),
             @"changed_within_days": @(kABWithinIntervalAroundToday), @"not_changed_within_days": @(kABNotWithinIntervalAroundToday),
             @"after": @(kABGreaterThanOrEqual), @"member_of": @25, @"not_member_of": @26};
}

// Fields by the names the tools use: AddressBook property, key and label.
static NSDictionary<NSString *, NSArray *> *Fields(void) {
    return @{@"first_name": @[kABFirstNameProperty], @"last_name": @[kABLastNameProperty], @"middle_name": @[kABMiddleNameProperty],
             @"phonetic_first_name": @[kABFirstNamePhoneticProperty], @"phonetic_last_name": @[kABLastNamePhoneticProperty],
             @"phonetic_middle_name": @[kABMiddleNamePhoneticProperty], @"nickname": @[kABNicknameProperty],
             @"organization": @[kABOrganizationProperty], @"department": @[kABDepartmentProperty], @"job_title": @[kABJobTitleProperty],
             @"note": @[kABNoteProperty], @"phone": @[kABPhoneProperty], @"email": @[kABEmailProperty], @"url": @[kABURLsProperty],
             @"instant_message": @[kABInstantMessageProperty], @"address": @[kABAddressProperty],
             @"street": @[kABAddressProperty, kABAddressStreetKey], @"city": @[kABAddressProperty, kABAddressCityKey],
             @"state": @[kABAddressProperty, kABAddressStateKey], @"zip": @[kABAddressProperty, kABAddressZIPKey],
             @"country": @[kABAddressProperty, kABAddressCountryKey], @"birthday": @[kABBirthdayProperty],
             @"anniversary": @[kABOtherDatesProperty, [NSNull null], kABAnniversaryLabel], @"date": @[kABOtherDatesProperty],
             @"modified": @[kABModificationDateProperty], @"group": @[@"ABParentGroups"]};
}

static NSArray<NSString *> *NameProperties(void) {
    return @[kABFirstNameProperty, kABFirstNamePhoneticProperty, kABLastNameProperty, kABLastNamePhoneticProperty,
             kABMiddleNameProperty, kABMiddleNamePhoneticProperty];
}

static ABSearchElement *Match(NSString *property, NSString *key, NSString *label, id value, ABSearchComparison comparison) {
    return [ABPerson searchElementForProperty:property label:label key:key value:value comparison:comparison];
}

// A conjunction with no children raises in AddressBook, so these answer nil for an empty list.
static ABSearchElement *Any(NSArray<ABSearchElement *> *children) {
    if (children.count == 0) return nil;
    return children.count == 1 ? children[0] : [ABSearchElement searchElementForConjunction:kABSearchOr children:children];
}

static ABSearchElement *All(NSArray<ABSearchElement *> *children) {
    if (children.count == 0) return nil;
    return children.count == 1 ? children[0] : [ABSearchElement searchElementForConjunction:kABSearchAnd children:children];
}

static NSDate *Day(NSString *text) {
    NSDateFormatter *format = [NSDateFormatter new];
    format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    format.dateFormat = @"yyyy-MM-dd";
    return [format dateFromString:text];
}

static ABSearchElement *Element(NSDictionary *criteria, ABAddressBook *book, NSError **error);

static ABSearchElement *Rule(NSDictionary *rule, ABAddressBook *book, NSError **error) {
    if (rule[@"rules"]) return Element(rule, book, error);
    NSString *field = rule[@"field"], *op = rule[@"op"];
    id value = rule[@"value"];
    if (value == [NSNull null]) value = nil;
    BOOL isSet = [op isEqual:@"is_set"], notSet = [op isEqual:@"is_not_set"];
    NSNumber *comparison = Comparisons()[op];
    if (!isSet && !notSet && !comparison) { if (error) *error = ABError([NSString stringWithFormat:@"Unknown comparison %@", op]); return nil; }
    ABSearchComparison cmp = isSet ? kABNotEqual : notSet ? kABEqual : (ABSearchComparison)comparison.integerValue;
    if (isSet || notSet) value = nil;

    if ([field isEqual:@"any"]) return Match(nil, nil, nil, value, cmp);
    if ([field isEqual:@"name"]) {
        // As Contacts' editor builds it: each word in any name part (first, middle, last and their
        // phonetic forms); a negation must hold for every part.
        BOOL negated = [op isEqual:@"not_contains"] || [op isEqual:@"is_not"] || notSet;
        NSArray *words = value ? [[value description] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet] : @[[NSNull null]];
        NSMutableArray *perWord = [NSMutableArray array];
        for (id word in words) {
            if ([word isKindOfClass:[NSString class]] && [word length] == 0) continue;
            NSMutableArray *parts = [NSMutableArray array];
            for (NSString *property in NameProperties()) [parts addObject:Match(property, nil, nil, word == [NSNull null] ? nil : word, cmp)];
            [perWord addObject:negated ? All(parts) : Any(parts)];
        }
        ABSearchElement *names = All(perWord);
        if (!names && error) *error = ABError(@"name takes at least one word");
        return names;
    }
    NSArray *path = Fields()[field];
    if (!path) { if (error) *error = ABError([NSString stringWithFormat:@"Unknown field %@", field]); return nil; }
    NSString *property = path[0];
    NSString *key = path.count > 1 && path[1] != [NSNull null] ? path[1] : nil;
    NSString *label = path.count > 2 ? path[2] : nil;

    if ([field isEqual:@"address"] && !isSet && !notSet) {
        BOOL negated = [op isEqual:@"not_contains"] || [op isEqual:@"is_not"];
        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *addressKey in @[kABAddressStreetKey, kABAddressCityKey, kABAddressStateKey, kABAddressZIPKey, kABAddressCountryKey]) {
            [parts addObject:Match(kABAddressProperty, addressKey, nil, value, cmp)];
        }
        return negated ? All(parts) : Any(parts);
    }
    if ([field isEqual:@"group"]) {
        id record = [value isKindOfClass:[NSString class]] ? [book recordForUniqueId:value] : nil;
        if (![record isKindOfClass:[ABGroup class]]) { if (error) *error = ABError([NSString stringWithFormat:@"No group or smart list with id %@", value]); return nil; }
        value = record;
    } else if ([op hasSuffix:@"_days"]) {
        value = @([value doubleValue] * 86400);
    } else if ([op isEqual:@"after"]) {
        NSDate *date = Day([value description]);
        if (!date) { if (error) *error = ABError(@"after takes a day like 2026-10-21"); return nil; }
        value = date;
    }
    return Match(property, key, label, value, cmp);
}

static ABSearchElement *Element(NSDictionary *criteria, ABAddressBook *book, NSError **error) {
    NSArray *rules = criteria[@"rules"];
    if (![rules isKindOfClass:[NSArray class]] || rules.count == 0) { if (error) *error = ABError(@"criteria need at least one rule"); return nil; }
    NSMutableArray *children = [NSMutableArray array];
    for (NSDictionary *rule in rules) {
        if (![rule isKindOfClass:[NSDictionary class]]) { if (error) *error = ABError(@"each rule must be an object"); return nil; }
        ABSearchElement *element = Rule(rule, book, error);
        if (!element) return nil;
        [children addObject:element];
    }
    return [criteria[@"match"] isEqual:@"any"] ? Any(children) : All(children);
}

/// Element() with AddressBook's exceptions turned into errors.
static ABSearchElement *SafeElement(NSDictionary *criteria, ABAddressBook *book, NSError **error) {
    @try {
        return Element(criteria, book, error);
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return nil;
    }
}

/// The stored search element back in the tools' form. Each match keeps its own field, so a "name"
/// rule reads back as the parts Contacts' editor expands it to.
static NSDictionary *Describe(id element) {
    if ([element isKindOfClass:NSClassFromString(@"ABSearchElementConjunction")]) {
        NSMutableArray *rules = [NSMutableArray array];
        for (id child in Send(element, @"_children") ?: @[]) [rules addObject:Describe(child)];
        NSInteger conjunction = SendInteger(element, @"conjunction");
        if (conjunction == NSNotFound) return @{@"field": @"unknown", @"op": @"unknown", @"value": [element description] ?: @""};
        return @{@"match": conjunction == kABSearchOr ? @"any" : @"all", @"rules": rules};
    }
    if (![element isKindOfClass:NSClassFromString(@"ABSearchElementMatch")]) return @{@"field": @"unknown", @"op": @"unknown", @"value": [element description] ?: @""};
    NSString *property = Send(element, @"_searchProperty"), *key = Send(element, @"_key"), *label = Send(element, @"_label");
    id value = Send(element, @"_value");
    NSInteger comparison = SendInteger(element, @"_comparison");
    if (comparison == NSNotFound) return @{@"field": @"unknown", @"op": @"unknown", @"value": [element description] ?: @""};
    NSString *field = property ? property : @"any";
    for (NSString *name in Fields()) {
        NSArray *path = Fields()[name];
        NSString *pathKey = path.count > 1 && path[1] != [NSNull null] ? path[1] : nil;
        NSString *pathLabel = path.count > 2 ? path[2] : nil;
        if ([path[0] isEqual:property] && (pathKey == key || [pathKey isEqual:key]) && (pathLabel == label || [pathLabel isEqual:label])) { field = name; break; }
    }
    NSString *op = [NSString stringWithFormat:@"comparison_%ld", (long)comparison];
    if (!value && comparison == kABNotEqual) op = @"is_set";
    else if (!value && comparison == kABEqual) op = @"is_not_set";
    else {
        NSDictionary *comparisons = Comparisons();
        for (NSString *name in comparisons) if ([comparisons[name] integerValue] == comparison) { op = name; break; }
    }
    NSMutableDictionary *rule = [@{@"field": field, @"op": op} mutableCopy];
    if ([value isKindOfClass:[ABRecord class]]) rule[@"value"] = [value uniqueId];
    else if ([value isKindOfClass:[NSDate class]]) {
        NSDateFormatter *format = [NSDateFormatter new];
        format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        format.dateFormat = @"yyyy-MM-dd";
        rule[@"value"] = [format stringFromDate:value];
    } else if ([value isKindOfClass:[NSNumber class]] && [op hasSuffix:@"_days"]) rule[@"value"] = @(llround([value doubleValue] / 86400));
    else if (value) rule[@"value"] = [value description];
    return rule;
}

static NSArray<NSString *> *IDs(NSArray *records) {
    NSMutableArray *ids = [NSMutableArray array];
    for (ABRecord *record in records) if (record.uniqueId) [ids addObject:record.uniqueId];
    return ids;
}

@implementation CSAddressBook

static ABPerson *Person(ABAddressBook *book, NSString *cardID, NSError **error) {
    id person = [book recordForUniqueId:cardID];
    if (![person isKindOfClass:[ABPerson class]]) {
        if (error) *error = ABError([NSString stringWithFormat:@"AddressBook does not know card %@", cardID]);
        return nil;
    }
    return person;
}

static NSArray *Linked(ABAddressBook *book, ABPerson *person) {
    SEL selector = NSSelectorFromString(@"peopleLinkedToPerson:sortDescriptors:");
    if (![book respondsToSelector:selector]) return @[person];
    NSArray *people = ((id (*)(id, SEL, id, id))objc_msgSend)(book, selector, person, nil);
    return people.count ? people : @[person];
}

+ (BOOL)linkCards:(NSArray<NSString *> *)cardIDs photoCard:(NSString *)photoCardID error:(NSError **)error {
    ABAddressBook *book = Book(error);
    if (!book) return NO;
    NSMutableArray *people = [NSMutableArray array];
    for (NSString *cardID in cardIDs) {
        ABPerson *person = Person(book, cardID, error);
        if (!person) return NO;
        [people addObject:person];
    }
    SEL link = NSSelectorFromString(@"linkPerson:toPerson:");
    SEL name = NSSelectorFromString(@"setPersonWithPreferredName:forLinkedPeople:");
    SEL photo = NSSelectorFromString(@"setPersonWithPreferredPhoto:forLinkedPeople:");
    if (![book respondsToSelector:link] || ![book respondsToSelector:name] || ![book respondsToSelector:photo]) {
        if (error) *error = ABError(@"This version of macOS cannot link cards");
        return NO;
    }
    for (ABPerson *other in [people subarrayWithRange:NSMakeRange(1, people.count - 1)]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(book, link, other, people[0]);
    }
    NSArray *linked = Linked(book, people[0]);
    ((void (*)(id, SEL, id, id))objc_msgSend)(book, name, people[0], linked);
    ABPerson *photoPerson = photoCardID ? Person(book, photoCardID, nil) : nil;
    ((void (*)(id, SEL, id, id))objc_msgSend)(book, photo, photoPerson ?: people[0], linked);
    return Save(book, error);
}

+ (BOOL)unlinkCard:(NSString *)cardID error:(NSError **)error {
    ABAddressBook *book = Book(error);
    if (!book) return NO;
    ABPerson *person = Person(book, cardID, error);
    if (!person) return NO;
    SEL unlink = NSSelectorFromString(@"unlinkPerson:");
    if (![book respondsToSelector:unlink]) { if (error) *error = ABError(@"This version of macOS cannot unlink cards"); return NO; }
    ((void (*)(id, SEL, id))objc_msgSend)(book, unlink, person);
    return Save(book, error);
}

+ (BOOL)preferCard:(NSString *)cardID forName:(BOOL)name error:(NSError **)error {
    ABAddressBook *book = Book(error);
    if (!book) return NO;
    ABPerson *person = Person(book, cardID, error);
    if (!person) return NO;
    SEL selector = NSSelectorFromString(name ? @"setPersonWithPreferredName:forLinkedPeople:" : @"setPersonWithPreferredPhoto:forLinkedPeople:");
    if (![book respondsToSelector:selector]) { if (error) *error = ABError(@"This version of macOS cannot choose the card"); return NO; }
    ((void (*)(id, SEL, id, id))objc_msgSend)(book, selector, person, Linked(book, person));
    return Save(book, error);
}

+ (BOOL)removeSubgroup:(NSString *)childID fromGroup:(NSString *)parentID error:(NSError **)error {
    ABAddressBook *book = Book(error);
    if (!book) return NO;
    id parent = [book recordForUniqueId:parentID], child = [book recordForUniqueId:childID];
    if (![parent isKindOfClass:[ABGroup class]] || ![child isKindOfClass:[ABGroup class]]) {
        if (error) *error = ABError(@"AddressBook does not know that group");
        return NO;
    }
    [(ABGroup *)parent removeSubgroup:child];
    return Save(book, error);
}

+ (NSArray<NSDictionary<NSString *, id> *> *)smartListsWithError:(NSError **)error {
    ABAddressBook *book = Book(error);
    if (!book) return nil;
    NSMutableArray *lists = [NSMutableArray array];
    NSArray *smart = Send(book, @"smartGroups");
    if (!smart) { if (error) *error = ABError(@"This version of macOS has no smart lists API"); return nil; }
    @try {
    for (id list in smart) {
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        row[@"id"] = [list uniqueId] ?: @"";
        row[@"name"] = [list valueForProperty:kABGroupNameProperty] ?: @"";
        if ([list respondsToSelector:NSSelectorFromString(@"tracksModification")]) row[@"highlight"] = @(((BOOL (*)(id, SEL))objc_msgSend)(list, NSSelectorFromString(@"tracksModification")));
        id element = Send(list, @"searchElement");
        if (element) {
            NSDictionary *criteria = Describe(element);
            row[@"criteria"] = criteria[@"rules"] ? criteria : @{@"match": @"all", @"rules": @[criteria]};
        }
        row[@"members"] = IDs([list members] ?: @[]);
        [lists addObject:row];
    }
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return nil;
    }
    return lists;
}

/// Whether smart lists can be written on this version of macOS.
static BOOL CanWriteSmartLists(NSError **error) {
    Class smartClass = SmartGroupClass();
    for (NSString *name in @[@"initWithAddressBook:account:", @"setSearchElement:", @"setTracksModification:"]) {
        if (!smartClass || ![smartClass instancesRespondToSelector:NSSelectorFromString(name)]) {
            if (error) *error = ABError(@"This version of macOS has no smart lists API");
            return NO;
        }
    }
    return YES;
}

static id LocalAccount(ABAddressBook *book) {
    NSString *__unsafe_unretained const *local = (NSString *__unsafe_unretained const *)dlsym(RTLD_DEFAULT, "ABLocalAccountIdentifier");
    id repository = Send(book, @"accountRepository");
    SEL find = NSSelectorFromString(@"accountWithIdentifier:");
    if (!local || !repository || ![repository respondsToSelector:find]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(repository, find, *local);
}

+ (NSString *)createSmartList:(NSString *)name criteria:(NSDictionary<NSString *, id> *)criteria highlight:(BOOL)highlight error:(NSError **)error {
    if (!CanWriteSmartLists(error)) return nil;
    ABAddressBook *book = Book(error);
    if (!book) return nil;
    ABSearchElement *element = SafeElement(criteria, book, error);
    if (!element) return nil;
    id account = LocalAccount(book);
    if (!account) { if (error) *error = ABError(@"AddressBook has no On My Mac account to keep smart lists in"); return nil; }
    @try {
        id list = [[SmartGroupClass() alloc] initWithAddressBook:book account:account];
        if (!list) { if (error) *error = ABError(@"AddressBook did not make the smart list"); return nil; }
        [list setValue:name forProperty:kABGroupNameProperty];
        ((void (*)(id, SEL, id))objc_msgSend)(list, NSSelectorFromString(@"setSearchElement:"), element);
        ((void (*)(id, SEL, BOOL))objc_msgSend)(list, NSSelectorFromString(@"setTracksModification:"), highlight);
        if (![book addRecord:list]) { if (error) *error = ABError(@"AddressBook did not take the new smart list"); return nil; }
        if (!Save(book, error)) return nil;
        return [list uniqueId];
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return nil;
    }
}

static id FindSmartList(ABAddressBook *book, NSString *identifier, NSError **error) {
    id list = [book recordForUniqueId:identifier];
    if (![list isKindOfClass:SmartGroupClass()]) {
        if (error) *error = ABError([NSString stringWithFormat:@"No smart list with id %@", identifier]);
        return nil;
    }
    return list;
}

+ (BOOL)updateSmartList:(NSString *)identifier name:(NSString *)name criteria:(NSDictionary<NSString *, id> *)criteria highlight:(NSNumber *)highlight error:(NSError **)error {
    if (!CanWriteSmartLists(error)) return NO;
    ABAddressBook *book = Book(error);
    if (!book) return NO;
    id list = FindSmartList(book, identifier, error);
    if (!list) return NO;
    ABSearchElement *element = nil;
    if (criteria) {
        element = SafeElement(criteria, book, error);
        if (!element) return NO;
    }
    @try {
        if (element) ((void (*)(id, SEL, id))objc_msgSend)(list, NSSelectorFromString(@"setSearchElement:"), element);
        if (name) [list setValue:name forProperty:kABGroupNameProperty];
        if (highlight) ((void (*)(id, SEL, BOOL))objc_msgSend)(list, NSSelectorFromString(@"setTracksModification:"), highlight.boolValue);
        return Save(book, error);
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return NO;
    }
}

+ (BOOL)deleteSmartList:(NSString *)identifier error:(NSError **)error {
    ABAddressBook *book = Book(error);
    if (!book) return NO;
    id list = FindSmartList(book, identifier, error);
    if (!list) return NO;
    [book removeRecord:list];  // answers NO even when it removes the record; the save decides
    if (!Save(book, error)) return NO;
    if ([Book(nil) recordForUniqueId:identifier]) { if (error) *error = ABError(@"The smart list is still there after deleting it"); return NO; }
    return YES;
}

+ (NSArray<NSString *> *)cardsMatchingCriteria:(NSDictionary<NSString *, id> *)criteria error:(NSError **)error {
    ABAddressBook *book = Book(error);
    if (!book) return nil;
    ABSearchElement *element = SafeElement(criteria, book, error);
    if (!element) return nil;
    NSMutableArray *people = [NSMutableArray array];
    @try {
        for (id record in [book recordsMatchingSearchElement:element] ?: @[]) if ([record isKindOfClass:[ABPerson class]]) [people addObject:record];
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return nil;
    }
    return IDs(people);
}

static NSDictionary<NSString *, NSString *> *DistributionProperties(void) {
    return @{@"email": kABEmailProperty, @"phone": kABPhoneProperty, @"address": kABAddressProperty};
}

+ (NSArray<NSDictionary<NSString *, id> *> *)distributionOfGroup:(NSString *)groupID error:(NSError **)error {
    ABAddressBook *book = Book(error);
    if (!book) return nil;
    id group = [book recordForUniqueId:groupID];
    if (![group isKindOfClass:[ABGroup class]]) { if (error) *error = ABError(@"AddressBook does not know that group"); return nil; }
    NSMutableArray *rows = [NSMutableArray array];
    for (ABPerson *person in [(ABGroup *)group members]) {
        NSMutableDictionary *row = [NSMutableDictionary dictionaryWithObject:person.uniqueId forKey:@"card"];
        [DistributionProperties() enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *property, BOOL *stop) {
            NSString *chosen = [(ABGroup *)group distributionIdentifierForProperty:property person:person];
            ABMultiValue *values = [person valueForProperty:property];
            if (chosen && values.count > 1 && ![chosen isEqual:values.primaryIdentifier]) row[name] = chosen;
        }];
        [rows addObject:row];
    }
    return rows;
}

+ (BOOL)setDistributionOfGroup:(NSString *)groupID card:(NSString *)cardID property:(NSString *)property value:(NSString *)valueID error:(NSError **)error {
    ABAddressBook *book = Book(error);
    if (!book) return NO;
    id group = [book recordForUniqueId:groupID], person = [book recordForUniqueId:cardID];
    NSString *abProperty = DistributionProperties()[property];
    if (![group isKindOfClass:[ABGroup class]] || ![person isKindOfClass:[ABPerson class]] || !abProperty) {
        if (error) *error = ABError(@"AddressBook does not know that group, card or property");
        return NO;
    }
    ABMultiValue *values = [person valueForProperty:abProperty];
    if ([values indexForIdentifier:valueID] == NSNotFound) {
        if (error) *error = ABError([NSString stringWithFormat:@"The card has no %@ with id %@", property, valueID]);
        return NO;
    }
    if (![(ABGroup *)group setDistributionIdentifier:valueID forProperty:abProperty person:person]) {
        if (error) *error = ABError(@"AddressBook refused the distribution choice");
        return NO;
    }
    return Save(book, error);
}

static id Repository(NSError **error) {
    if (!Book(error)) return nil;
    Class repositoryClass = NSClassFromString(@"ABAccountRepository");
    id repository = [repositoryClass respondsToSelector:NSSelectorFromString(@"sharedRepository")] ? Send(repositoryClass, @"sharedRepository") : nil;
    if (!repository && error) *error = ABError(@"This version of macOS has no account repository");
    return repository;
}

static id Value(id object, NSString *key) {
    @try { return [object valueForKey:key]; } @catch (NSException *exception) { return nil; }
}

+ (NSArray<NSDictionary<NSString *, id> *> *)accountsWithError:(NSError **)error {
    id repository = Repository(error);
    if (!repository) return nil;
    NSString *defaultID = Value(Send(repository, @"defaultAccount"), @"identifier");
    NSArray *defaultable = Send(repository, @"defaultableAccounts") ?: @[];
    NSMutableSet *canBeDefault = [NSMutableSet set];
    for (id account in defaultable) { NSString *identifier = Value(account, @"identifier"); if (identifier) [canBeDefault addObject:identifier]; }
    NSMutableArray *rows = [NSMutableArray array];
    for (id account in Send(repository, @"allAccounts") ?: @[]) {
        NSString *identifier = Value(account, @"identifier");
        if (!identifier) continue;
        NSMutableDictionary *row = [NSMutableDictionary dictionaryWithObject:identifier forKey:@"id"];
        id name = Value(account, @"name"), type = Value(account, @"accountTypeIdentifier");
        if ([name isKindOfClass:[NSString class]]) row[@"name"] = name;
        if ([type isKindOfClass:[NSString class]]) row[@"type"] = type;
        row[@"default"] = @([identifier isEqual:defaultID]);
        row[@"can_be_default"] = @([canBeDefault containsObject:identifier]);
        id main = Value(account, @"isMainAccount");
        if (main) row[@"main"] = main;
        [rows addObject:row];
    }
    return rows;
}

+ (BOOL)setDefaultAccount:(NSString *)accountID error:(NSError **)error {
    id repository = Repository(error);
    if (!repository) return NO;
    id account = nil;
    for (id candidate in Send(repository, @"defaultableAccounts") ?: @[]) if ([Value(candidate, @"identifier") isEqual:accountID]) account = candidate;
    if (!account) { if (error) *error = ABError(@"That account cannot hold new cards by default (Contacts allows iCloud, Google and On My Mac)"); return NO; }
    SEL setter = NSSelectorFromString(@"setDefaultAccount:");
    if (![repository respondsToSelector:setter]) { if (error) *error = ABError(@"This version of macOS cannot set the default account"); return NO; }
    ((void (*)(id, SEL, id))objc_msgSend)(repository, setter, account);
    NSString *now = Value(Send(repository, @"defaultAccount"), @"identifier");
    if (![now isEqual:accountID]) { if (error) *error = ABError(@"Contacts kept its previous default account"); return NO; }
    return YES;
}

+ (BOOL)syncAccounts:(NSArray<NSString *> *)accountIDs error:(NSError **)error {
    SEL selector = NSSelectorFromString(@"_remotelySyncSourcesWithIdentifiers:");
    if (![ABAddressBook respondsToSelector:selector]) { if (error) *error = ABError(@"This version of macOS cannot ask Contacts to sync"); return NO; }
    ((void (*)(id, SEL, id))objc_msgSend)([ABAddressBook class], selector, accountIDs);
    return YES;
}

@end
