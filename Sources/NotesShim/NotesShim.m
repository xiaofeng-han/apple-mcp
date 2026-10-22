#import "NotesShim.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

// The private methods used here, declared so the compiler emits correctly typed message sends.
// Nothing implements these protocols; objects are only cast to them.

@protocol ANContainerClass
+ (NSManagedObjectModel *)managedObjectModel;
+ (NSDictionary *)standardStoreOptions;
@end

@protocol ANNoteContextClass
+ (void)startSharedContextWithOptions:(NSUInteger)options;
+ (id)sharedContext;
@end

@protocol ANNoteContext
- (NSPersistentContainer *)persistentContainer;
@end

@protocol ANNoteClass
+ (id)newEmptyNoteInFolder:(id)folder;
+ (id)duplicateNote:(id)note intoFolder:(id)folder isPasswordProtected:(BOOL)locked removeOriginalNote:(BOOL)remove;
@end

@protocol ANNote
- (id)mergeableString;
- (id)document;
- (void)beginEditing;
- (void)endEditing;
- (void)saveNoteData;
- (void)edited:(NSUInteger)mask range:(NSRange)range changeInLength:(NSInteger)delta;
- (id)addTableAttachmentWithText:(NSAttributedString *)text;
@end

@protocol ANMergeableString
- (NSAttributedString *)attributedString;
- (void)insertAttributedString:(NSAttributedString *)string atIndex:(NSUInteger)index;
- (void)deleteCharactersInRange:(NSRange)range;
- (void)setAttributes:(NSDictionary *)attributes range:(NSRange)range;
- (void)insertString:(NSString *)string atIndex:(NSUInteger)index;
- (void)beginEditing;
- (void)endEditing;
@end

@protocol ANPinnable
- (void)setIsPinned:(BOOL)pinned;
@end

@protocol ANAttaching
- (id)addAttachmentWithFileURL:(NSURL *)url;
- (id)addURLAttachmentWithURL:(NSURL *)url;
@end

@protocol ANSynced
- (id)cloudState;
- (void)markForDeletion;
- (void)unmarkForDeletion;
- (void)updateChangeCountWithReason:(NSString *)reason;
- (id)attachmentModel;
@end

@protocol ANMarker
- (id)attachmentInContext:(NSManagedObjectContext *)context;
@end

@protocol ANTableModel
- (id)table;
- (void)setMergeableDataDirty:(BOOL)dirty;
- (void)writeMergeableData;
@end

@protocol ANTable
- (NSUInteger)rowCount;
- (NSUInteger)columnCount;
- (id)stringForColumnIndex:(NSUInteger)column rowIndex:(NSUInteger)row;
- (id)identifierForColumnAtIndex:(NSUInteger)index;
- (id)identifierForRowAtIndex:(NSUInteger)index;
- (id)mergeableStringForColumnID:(id)column rowID:(id)row;
- (void)setAttributedString:(NSAttributedString *)string columnIndex:(NSUInteger)column rowIndex:(NSUInteger)row;
- (void)insertRowAtIndex:(NSUInteger)index;
- (void)removeRowAtIndex:(NSUInteger)index;
- (void)insertColumnAtIndex:(NSUInteger)index;
- (void)removeColumnAtIndex:(NSUInteger)index;
@end

@protocol ANParagraphStyle
- (void)setStyle:(NSUInteger)style;
- (void)setIndent:(NSUInteger)indent;
- (void)setBlockQuoteLevel:(NSUInteger)level;
- (id)todo;
@end

@protocol ANTodo
- (instancetype)initWithIdentifier:(NSUUID *)identifier done:(BOOL)done;
- (id)todoWithDone:(BOOL)done;
@end

@protocol ANInlineAttachmentClass
+ (id)newHashtagAttachmentWithIdentifier:(NSString *)identifier hashtagText:(NSString *)text
              creatingHashtagIfNecessary:(BOOL)create note:(id)note parentAttachment:(id)parent;
+ (void)reviveOrTouchHashtag:(id)attachment;
+ (void)renameHashtagsWithStandardizedContent:(NSString *)content newDisplayText:(NSString *)name context:(NSManagedObjectContext *)context;
+ (id)newLinkAttachmentWithIdentifier:(NSString *)identifier toNote:(id)target fromNote:(id)note parentAttachment:(id)parent;
+ (id)newDividerLineAttachmentWithIdentifier:(NSString *)identifier note:(id)note parentAttachment:(id)parent;
@end

@protocol ANAudioDocumentClass
+ (void)registerWithICCRCoder;
+ (id)unarchiveFromData:(NSData *)data replicaID:(NSUUID *)replicaID;
@end

@protocol ANAudioDocument
- (NSString *)transcriptAsPlainText;
- (NSString *)recordingSummaryAsPlainText;
- (NSString *)topLineSummaryAsPlainText;
- (BOOL)isCallRecording;
@end

static NSString *const ANErrorDomain = @"AppleNotesMCP.NotesShared";

static NSError *ANError(NSString *message) {
    return [NSError errorWithDomain:ANErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// Runs `body`, turning an Objective-C exception into an error that names `what`.
static BOOL ANTry(NSString *what, NSError **error, NS_NOESCAPE void (^body)(void)) {
    @try {
        body();
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = ANError([NSString stringWithFormat:@"%@ failed in NotesShared: %@: %@", what, exception.name, exception.reason ?: @""]);
        return NO;
    }
}

/// The text of a table cell, which NotesShared gives as an attributed string or a string.
static NSString *ANPlain(id value) {
    if ([value isKindOfClass:[NSAttributedString class]]) return [(NSAttributedString *)value string];
    if ([value isKindOfClass:[NSString class]]) return value;
    return @"";
}

static NSArray<NSArray<NSString *> *> *ANRows(id table) {
    id<ANTable> t = table;
    NSUInteger rows = [t rowCount], columns = [t columnCount];
    if (rows == 0 || columns == 0) return nil;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:rows];
    for (NSUInteger r = 0; r < rows; r++) {
        NSMutableArray *cells = [NSMutableArray arrayWithCapacity:columns];
        for (NSUInteger c = 0; c < columns; c++) [cells addObject:ANPlain([t stringForColumnIndex:c rowIndex:r])];
        [out addObject:cells];
    }
    return out;
}

/// What NotesShared needs from NotesEditor.framework to create a table:
/// -[NSMutableAttributedString ic_convertParagraphStyleToBodyInRange:]. Loading NotesEditor
/// itself makes later edits in the middle of a note save a truncated body, so this supplies the
/// method instead: every character in the range gets a body paragraph style, which table cells
/// need to lay out.
static void ANInstallBodyStyleConversion(void) {
    SEL selector = NSSelectorFromString(@"ic_convertParagraphStyleToBodyInRange:");
    Class stringClass = [NSMutableAttributedString class];
    if ([stringClass instancesRespondToSelector:selector]) return;
    IMP implementation = imp_implementationWithBlock(^(NSMutableAttributedString *string, NSRange range) {
        Class styleClass = NSClassFromString(@"ICTTParagraphStyle");
        if (!styleClass) return;
        NSMutableArray<NSArray *> *changes = [NSMutableArray array];
        [string enumerateAttribute:@"TTStyle" inRange:range options:0 usingBlock:^(id value, NSRange run, BOOL *stop) {
            id<ANParagraphStyle> style = value ? [value mutableCopy] : [[styleClass alloc] init];
            [style setStyle:3];
            [changes addObject:@[[NSValue valueWithRange:run], style]];
        }];
        for (NSArray *change in changes) [string addAttribute:@"TTStyle" value:change[1] range:[change[0] rangeValue]];
    });
    class_addMethod(stringClass, selector, implementation, "v@:{_NSRange=QQ}");
}

@implementation ANNotes

static BOOL loaded = NO;

+ (BOOL)loadFramework:(NSError **)error {
    if (loaded) return YES;
    if (!dlopen("/System/Library/PrivateFrameworks/NotesShared.framework/NotesShared", RTLD_NOW)) {
        if (error) *error = ANError([NSString stringWithFormat:@"cannot load NotesShared: %s", dlerror()]);
        return NO;
    }
    NSDictionary<NSString *, NSArray<NSString *> *> *classMethods = @{
        @"ICPersistentContainer": @[@"managedObjectModel", @"standardStoreOptions"],
        @"ICNoteContext": @[@"startSharedContextWithOptions:", @"sharedContext"],
        @"ICNote": @[@"newEmptyNoteInFolder:"],
    };
    NSDictionary<NSString *, NSArray<NSString *> *> *instanceMethods = @{
        @"ICNote": @[@"mergeableString", @"document", @"beginEditing", @"endEditing", @"saveNoteData",
                     @"edited:range:changeInLength:", @"addTableAttachmentWithText:"],
        @"ICTTParagraphStyle": @[@"setStyle:", @"setIndent:", @"setBlockQuoteLevel:", @"todo"],
        @"ICTTTodo": @[@"initWithIdentifier:done:", @"todoWithDone:"],
        @"ICTTAttachment": @[@"attachmentInContext:"],
        @"ICAttachment": @[@"attachmentModel", @"markForDeletion", @"updateChangeCountWithReason:"],
        @"ICAttachmentTableModel": @[@"table", @"setMergeableDataDirty:", @"writeMergeableData"],
        @"ICTable": @[@"rowCount", @"columnCount", @"stringForColumnIndex:rowIndex:", @"identifierForColumnAtIndex:",
                      @"identifierForRowAtIndex:", @"mergeableStringForColumnID:rowID:",
                      @"setAttributedString:columnIndex:rowIndex:", @"insertRowAtIndex:", @"removeRowAtIndex:",
                      @"insertColumnAtIndex:", @"removeColumnAtIndex:"],
    };
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSString *name in classMethods) {
        Class cls = NSClassFromString(name);
        if (!cls) { [missing addObject:name]; continue; }
        for (NSString *selector in classMethods[name]) {
            if (![cls respondsToSelector:NSSelectorFromString(selector)]) [missing addObject:[NSString stringWithFormat:@"+[%@ %@]", name, selector]];
        }
    }
    for (NSString *name in instanceMethods) {
        Class cls = NSClassFromString(name);
        if (!cls) { [missing addObject:name]; continue; }
        for (NSString *selector in instanceMethods[name]) {
            if (![cls instancesRespondToSelector:NSSelectorFromString(selector)]) [missing addObject:[NSString stringWithFormat:@"-[%@ %@]", name, selector]];
        }
    }
    if (missing.count > 0) {
        NSArray *sorted = [missing sortedArrayUsingSelector:@selector(compare:)];
        if (error) *error = ANError([@"NotesShared changed in this version of macOS; missing " stringByAppendingString:[sorted componentsJoinedByString:@", "]]);
        return NO;
    }
    loaded = YES;
    return YES;
}

+ (NSManagedObjectModel *)managedObjectModel:(NSError **)error {
    if (![self loadFramework:error]) return nil;
    __block NSManagedObjectModel *model = nil;
    if (!ANTry(@"reading Notes' data model", error, ^{
        model = [(id<ANContainerClass>)NSClassFromString(@"ICPersistentContainer") managedObjectModel];
    })) return nil;
    if (!model && error) *error = ANError(@"NotesShared returned no data model");
    return model;
}

+ (NSDictionary<NSString *, id> *)storeOptions:(NSError **)error {
    if (![self loadFramework:error]) return nil;
    __block NSDictionary *options = nil;
    if (!ANTry(@"reading Notes' store options", error, ^{
        options = [(id<ANContainerClass>)NSClassFromString(@"ICPersistentContainer") standardStoreOptions];
    })) return nil;
    return options ?: @{};
}

+ (NSManagedObjectContext *)sharedContext:(NSError **)error {
    static NSManagedObjectContext *context = nil;
    if (context) return context;
    if (![self loadFramework:error]) return nil;
    __block NSManagedObjectContext *found = nil;
    if (!ANTry(@"starting Notes' shared context", error, ^{
        id<ANNoteContextClass> noteContext = (id<ANNoteContextClass>)NSClassFromString(@"ICNoteContext");
        [noteContext startSharedContextWithOptions:0];
        found = [[(id<ANNoteContext>)[noteContext sharedContext] persistentContainer] viewContext];
    })) return nil;
    if (!found) {
        if (error) *error = ANError(@"Notes' shared context has no view context");
        return nil;
    }
    context = found;
    return context;
}

+ (id)valueForKey:(NSString *)key of:(id)object {
    @try {
        return [object valueForKey:key];
    } @catch (NSException *exception) {
        return nil;
    }
}

+ (NSPredicate *)predicateOfSmartFolder:(NSManagedObject *)folder {
    __block NSPredicate *predicate = nil;
    ANTry(@"reading a smart folder", NULL, ^{
        id query = [folder valueForKey:@"smartFolderQueryObjC"];
        id value = [query valueForKey:@"predicate"];
        if ([value isKindOfClass:[NSPredicate class]]) predicate = value;
    });
    return predicate;
}

+ (NSString *)descriptionOfSmartFolder:(NSManagedObject *)folder {
    id value = [self valueForKey:@"smartFolderDescriptionObjC" of:folder];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

+ (NSAttributedString *)bodyOfNote:(NSManagedObject *)note error:(NSError **)error {
    __block NSAttributedString *body = nil;
    if (!ANTry(@"reading the note body", error, ^{
        body = [[[(id<ANNote>)note mergeableString] attributedString] copy];
    })) return nil;
    return body ?: [[NSAttributedString alloc] init];
}

+ (NSArray<NSArray<NSString *> *> *)rowsOfTableMarker:(id)marker context:(NSManagedObjectContext *)context {
    if (![self sharedContext:NULL]) return nil;
    __block NSArray *rows = nil;
    ANTry(@"reading a table", NULL, ^{
        id attachment = [(id<ANMarker>)marker attachmentInContext:context];
        id table = [(id<ANTableModel>)[(id<ANSynced>)attachment attachmentModel] table];
        if (table) rows = ANRows(table);
    });
    return rows;
}

+ (NSArray<NSArray<NSString *> *> *)rowsOfTableAttachment:(NSManagedObject *)attachment {
    if (![self sharedContext:NULL]) return nil;
    __block NSArray *rows = nil;
    ANTry(@"reading a table", NULL, ^{
        id table = [(id<ANTableModel>)[(id<ANSynced>)attachment attachmentModel] table];
        if (table) rows = ANRows(table);
    });
    return rows;
}

+ (BOOL)cloudStateOf:(NSManagedObject *)object local:(NSInteger *)local synced:(NSInteger *)synced {
    __block BOOL found = NO;
    ANTry(@"reading the iCloud state", NULL, ^{
        id state = [(id<ANSynced>)object cloudState];
        if (!state) return;
        *local = [[state valueForKey:@"currentLocalVersion"] integerValue];
        *synced = [[state valueForKey:@"latestVersionSyncedToCloud"] integerValue];
        found = YES;
    });
    return found;
}

+ (NSManagedObject *)newNoteInFolder:(NSManagedObject *)folder error:(NSError **)error {
    __block NSManagedObject *note = nil;
    if (!ANTry(@"creating a note", error, ^{
        note = (NSManagedObject *)[(id<ANNoteClass>)NSClassFromString(@"ICNote") newEmptyNoteInFolder:folder];
    })) return nil;
    if (!note && error) *error = ANError(@"NotesShared created no note");
    return note;
}

+ (NSString *)newTagNamed:(NSString *)name inNote:(NSManagedObject *)note error:(NSError **)error {
    Class cls = NSClassFromString(@"ICInlineAttachment");
    SEL make = @selector(newHashtagAttachmentWithIdentifier:hashtagText:creatingHashtagIfNecessary:note:parentAttachment:);
    if (![cls respondsToSelector:make]) {
        if (error) *error = ANError(@"NotesShared cannot make tags in this version of macOS");
        return nil;
    }
    __block NSString *identifier = nil;
    if (!ANTry(@"making a tag", error, ^{
        id attachment = [(id<ANInlineAttachmentClass>)cls newHashtagAttachmentWithIdentifier:[[NSUUID UUID] UUIDString] hashtagText:name
                                                                 creatingHashtagIfNecessary:YES note:note parentAttachment:nil];
        id value = [attachment valueForKey:@"identifier"];
        if ([value isKindOfClass:[NSString class]]) identifier = value;
    })) return nil;
    if (!identifier && error) *error = ANError(@"NotesShared made no tag");
    return identifier;
}

/// The identifier of an inline attachment `make` returns, or an error naming `what`.
static NSString *ANInline(NSString *what, SEL selector, NSError **error, id (^make)(id<ANInlineAttachmentClass> cls)) {
    Class cls = NSClassFromString(@"ICInlineAttachment");
    if (![cls respondsToSelector:selector]) {
        if (error) *error = ANError([NSString stringWithFormat:@"NotesShared cannot make %@ in this version of macOS", what]);
        return nil;
    }
    __block NSString *identifier = nil;
    if (!ANTry([@"making " stringByAppendingString:what], error, ^{
        id attachment = make((id<ANInlineAttachmentClass>)cls);
        id value = [attachment valueForKey:@"identifier"];
        if ([value isKindOfClass:[NSString class]]) identifier = value;
    })) return nil;
    if (!identifier && error) *error = ANError([NSString stringWithFormat:@"NotesShared made no %@", what]);
    return identifier;
}

+ (NSString *)newLinkToNote:(NSManagedObject *)target text:(NSString *)text inNote:(NSManagedObject *)note error:(NSError **)error {
    return ANInline(@"a note link", @selector(newLinkAttachmentWithIdentifier:toNote:fromNote:parentAttachment:), error, ^id(id<ANInlineAttachmentClass> cls) {
        id link = [cls newLinkAttachmentWithIdentifier:[[NSUUID UUID] UUIDString] toNote:target fromNote:note parentAttachment:nil];
        if (text.length > 0 && ![[link valueForKey:@"altText"] isEqual:text]) [link setValue:text forKey:@"altText"];
        return link;
    });
}

/// The identifier and type of an attachment `make` adds, or an error naming `what`.
static NSString *ANAttached(NSString *what, NSString **type, NSError **error, id (^make)(void)) {
    __block NSString *identifier = nil, *uti = nil;
    if (!ANTry([@"adding " stringByAppendingString:what], error, ^{
        id attachment = make();
        id value = [attachment valueForKey:@"identifier"], kind = [attachment valueForKey:@"typeUTI"];
        if ([value isKindOfClass:[NSString class]]) identifier = value;
        if ([kind isKindOfClass:[NSString class]]) uti = kind;
    })) return nil;
    if (!identifier && error) *error = ANError([NSString stringWithFormat:@"NotesShared added no %@", what]);
    *type = uti;
    return identifier;
}

+ (NSString *)addFile:(NSURL *)file title:(NSString *)title toNote:(NSManagedObject *)note type:(NSString **)type error:(NSError **)error {
    if (![note respondsToSelector:@selector(addAttachmentWithFileURL:)]) {
        if (error) *error = ANError(@"NotesShared cannot add files in this version of macOS");
        return nil;
    }
    return ANAttached(@"a file", type, error, ^id {
        id attachment = [(id<ANAttaching>)note addAttachmentWithFileURL:file];
        if (title.length > 0) [attachment setValue:title forKey:@"userTitle"];
        return attachment;
    });
}

+ (NSString *)addLinkCard:(NSURL *)url toNote:(NSManagedObject *)note type:(NSString **)type error:(NSError **)error {
    if (![note respondsToSelector:@selector(addURLAttachmentWithURL:)]) {
        if (error) *error = ANError(@"NotesShared cannot add link cards in this version of macOS");
        return nil;
    }
    return ANAttached(@"a link card", type, error, ^id { return [(id<ANAttaching>)note addURLAttachmentWithURL:url]; });
}

+ (NSString *)newDividerInNote:(NSManagedObject *)note error:(NSError **)error {
    return ANInline(@"a divider line", @selector(newDividerLineAttachmentWithIdentifier:note:parentAttachment:), error, ^id(id<ANInlineAttachmentClass> cls) {
        return [cls newDividerLineAttachmentWithIdentifier:[[NSUUID UUID] UUIDString] note:note parentAttachment:nil];
    });
}

+ (BOOL)renameTag:(NSManagedObject *)tag to:(NSString *)name error:(NSError **)error {
    Class cls = NSClassFromString(@"ICHashtag");
    if (![cls respondsToSelector:@selector(renameHashtagsWithStandardizedContent:newDisplayText:context:)]) {
        if (error) *error = ANError(@"NotesShared cannot rename tags in this version of macOS");
        return NO;
    }
    return ANTry(@"renaming the tag", error, ^{
        [(id<ANInlineAttachmentClass>)cls renameHashtagsWithStandardizedContent:[tag valueForKey:@"standardizedContent"] newDisplayText:name
                                                                        context:tag.managedObjectContext];
    });
}

+ (BOOL)reviveTagOfAttachment:(NSManagedObject *)attachment error:(NSError **)error {
    Class cls = NSClassFromString(@"ICInlineAttachment");
    if (![cls respondsToSelector:@selector(reviveOrTouchHashtag:)]) return YES;
    return ANTry(@"keeping a tag", error, ^{ [(id<ANInlineAttachmentClass>)cls reviveOrTouchHashtag:attachment]; });
}

+ (NSManagedObject *)duplicateNote:(NSManagedObject *)note intoFolder:(NSManagedObject *)folder error:(NSError **)error {
    if (!dlopen("/System/Library/PrivateFrameworks/NotesUI.framework/NotesUI", RTLD_NOW)) {
        if (error) *error = ANError([NSString stringWithFormat:@"cannot load NotesUI: %s", dlerror()]);
        return nil;
    }
    Class cls = NSClassFromString(@"ICNote");
    if (![cls respondsToSelector:@selector(duplicateNote:intoFolder:isPasswordProtected:removeOriginalNote:)]) {
        if (error) *error = ANError(@"NotesShared cannot copy notes in this version of macOS");
        return nil;
    }
    __block NSManagedObject *copy = nil;
    if (!ANTry(@"copying the note", error, ^{
        id made = [(id<ANNoteClass>)cls duplicateNote:note intoFolder:folder isPasswordProtected:NO removeOriginalNote:NO];
        if ([made isKindOfClass:[NSManagedObject class]]) copy = made;
    })) return nil;
    if (!copy && error) *error = ANError(@"NotesShared made no copy");
    return copy;
}

+ (NSString *)newSmartFolderNamed:(NSString *)name tags:(NSArray<NSManagedObject *> *)tags matchAll:(BOOL)all
                           account:(NSManagedObject *)account error:(NSError **)error {
    Class selection = NSClassFromString(@"ICTagSelection"), query = NSClassFromString(@"ICQueryObjC"), folders = NSClassFromString(@"ICFolder");
    SEL make = NSSelectorFromString(@"initWithManagedObjectContext:includedObjectIDs:excludedObjectIDs:tagOperator:");
    SEL ask = NSSelectorFromString(@"objc_queryForNotesMatchingTagSelection:"), smart = NSSelectorFromString(@"objc_smartFolderWithQuery:account:");
    if (![selection instancesRespondToSelector:make] || ![query respondsToSelector:ask] || ![folders respondsToSelector:smart]) {
        if (error) *error = ANError(@"NotesShared cannot make smart folders in this version of macOS");
        return nil;
    }
    __block NSString *identifier = nil;
    if (!ANTry(@"making a smart folder", error, ^{
        NSSet *ids = [NSSet setWithArray:[tags valueForKey:@"objectID"]];
        // The tag operator: 0 any of the tags, 1 all of them.
        id chosen = ((id (*)(id, SEL, id, id, id, NSInteger))objc_msgSend)([selection alloc], make, account.managedObjectContext, ids, [NSSet set], all ? 1 : 0);
        id rule = ((id (*)(id, SEL, id))objc_msgSend)(query, ask, chosen);
        NSManagedObject *folder = ((id (*)(id, SEL, id, id))objc_msgSend)(folders, smart, rule, account);
        [folder setValue:name forKey:@"title"];
        id value = [folder valueForKey:@"identifier"];
        if ([value isKindOfClass:[NSString class]]) identifier = value;
    })) return nil;
    if (!identifier && error) *error = ANError(@"NotesShared made no smart folder");
    return identifier;
}

+ (BOOL)renameFolder:(NSManagedObject *)folder to:(NSString *)name error:(NSError **)error {
    return ANTry(@"renaming the folder", error, ^{
        [folder setValue:name forKey:@"title"];
        [folder setValue:[NSDate date] forKey:@"dateForLastTitleModification"];
        [(id<ANSynced>)folder updateChangeCountWithReason:@"Renamed folder"];
    });
}

+ (BOOL)moveFolder:(NSManagedObject *)folder intoParent:(NSManagedObject *)parent error:(NSError **)error {
    return ANTry(@"moving the folder", error, ^{
        [folder setValue:parent forKey:@"parent"];
        // Notes settles a folder moved on two devices by this date.
        [folder setValue:[NSDate date] forKey:@"parentModificationDate"];
        [(id<ANSynced>)folder updateChangeCountWithReason:@"Moved folder"];
    });
}

+ (BOOL)setPinned:(BOOL)pinned ofNote:(NSManagedObject *)note error:(NSError **)error {
    if (![note respondsToSelector:@selector(setIsPinned:)]) {
        if (error) *error = ANError(@"NotesShared cannot pin notes in this version of macOS");
        return NO;
    }
    return ANTry(@"pinning the note", error, ^{
        [(id<ANPinnable>)note setIsPinned:pinned];
        [(id<ANSynced>)note updateChangeCountWithReason:pinned ? @"Pinned note" : @"Unpinned note"];
    });
}

+ (BOOL)unmarkForDeletion:(NSManagedObject *)object error:(NSError **)error {
    if (![object respondsToSelector:@selector(unmarkForDeletion)]) {
        if (error) *error = ANError(@"NotesShared cannot take back a deletion in this version of macOS");
        return NO;
    }
    return ANTry(@"keeping a tag", error, ^{
        [(id<ANSynced>)object unmarkForDeletion];
        [(id<ANSynced>)object updateChangeCountWithReason:@"Tag in use"];
    });
}

+ (BOOL)markForDeletion:(NSManagedObject *)object error:(NSError **)error {
    return ANTry(@"deleting an attachment", error, ^{ [(id<ANSynced>)object markForDeletion]; });
}

+ (id)paragraphStyle:(NSInteger)style indent:(NSInteger)indent quote:(NSInteger)quote checked:(NSInteger)checked
             basedOn:(id)existing error:(NSError **)error {
    if (![self loadFramework:error]) return nil;
    __block id result = nil;
    if (!ANTry(@"making a paragraph style", error, ^{
        id<ANParagraphStyle> made = existing ? [existing mutableCopy] : [[NSClassFromString(@"ICTTParagraphStyle") alloc] init];
        [made setStyle:(NSUInteger)style];
        [made setIndent:(NSUInteger)MAX(indent, 0)];
        [made setBlockQuoteLevel:(NSUInteger)MAX(quote, 0)];
        id todo = nil;
        if (checked >= 0) {
            id current = [made todo];
            todo = current ? [(id<ANTodo>)current todoWithDone:checked == 1]
                           : [(id<ANTodo>)[NSClassFromString(@"ICTTTodo") alloc] initWithIdentifier:[NSUUID UUID] done:checked == 1];
        }
        [(NSObject *)made setValue:todo forKey:@"todo"];
        result = made;
    })) return nil;
    return result;
}

+ (id)attachmentMarkerWithID:(NSString *)identifier type:(NSString *)type {
    Class cls = NSClassFromString(@"ICTTAttachment");
    if (!cls) return nil;
    __block NSObject *marker = nil;
    ANTry(@"making an attachment marker", NULL, ^{
        marker = [[cls alloc] init];
        [marker setValue:identifier forKey:@"attachmentIdentifier"];
        [marker setValue:type forKey:@"attachmentUTI"];
    });
    return marker;
}

+ (NSString *)markerID:(id)marker {
    id value = [self valueForKey:@"attachmentIdentifier" of:marker];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

+ (NSString *)markerType:(id)marker {
    id value = [self valueForKey:@"attachmentUTI" of:marker];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

@end

@implementation ANBodyEdit {
    NSManagedObject *_note;
    id<ANMergeableString> _string;
}

- (instancetype)initWithNote:(NSManagedObject *)note error:(NSError **)error {
    if (!(self = [super init])) return nil;
    __block id string = nil;
    __block NSAttributedString *original = nil;
    if (!ANTry(@"opening the note for editing", error, ^{
        string = [[(id<ANNote>)note document] mergeableString];
        original = [[(id<ANMergeableString>)string attributedString] copy];
    })) return nil;
    if (!string || !original) {
        if (error) *error = ANError(@"the note has no editable body");
        return nil;
    }
    _note = note;
    _string = string;
    _original = original;
    return self;
}

- (BOOL)begin:(NSError **)error {
    return ANTry(@"starting the edit", error, ^{ [(id<ANNote>)self->_note beginEditing]; });
}

- (BOOL)insert:(NSAttributedString *)text atIndex:(NSUInteger)index error:(NSError **)error {
    if (text.length == 0) return YES;
    return ANTry(@"inserting text", error, ^{
        [self->_string insertAttributedString:text atIndex:index];
        [(id<ANNote>)self->_note edited:3 range:NSMakeRange(index, text.length) changeInLength:(NSInteger)text.length];
    });
}

- (BOOL)deleteRange:(NSRange)range error:(NSError **)error {
    if (range.length == 0) return YES;
    return ANTry(@"deleting text", error, ^{
        [self->_string deleteCharactersInRange:range];
        [(id<ANNote>)self->_note edited:3 range:NSMakeRange(range.location, 0) changeInLength:-(NSInteger)range.length];
    });
}

- (BOOL)setAttributes:(NSDictionary<NSAttributedStringKey, id> *)attributes range:(NSRange)range error:(NSError **)error {
    if (range.length == 0) return YES;
    return ANTry(@"formatting text", error, ^{
        [self->_string setAttributes:attributes range:range];
        [(id<ANNote>)self->_note edited:1 range:range changeInLength:0];
    });
}

- (BOOL)end:(NSError **)error {
    return ANTry(@"saving the edit", error, ^{
        // Edits in place leave the modification date alone; Notes sorts by it.
        [self->_note setValue:[NSDate date] forKey:@"modificationDate"];
        [(id<ANNote>)self->_note endEditing];
        [(id<ANNote>)self->_note saveNoteData];
    });
}

- (NSString *)addTableWithText:(NSString *)text error:(NSError **)error {
    ANInstallBodyStyleConversion();
    __block NSString *identifier = nil;
    if (!ANTry(@"creating a table", error, ^{
        id attachment = [(id<ANNote>)self->_note addTableAttachmentWithText:[[NSAttributedString alloc] initWithString:text]];
        id value = [attachment valueForKey:@"identifier"];
        if ([value isKindOfClass:[NSString class]]) identifier = value;
    })) return nil;
    if (!identifier && error) *error = ANError(@"NotesShared created no table");
    return identifier;
}

@end

@implementation ANRecording

+ (instancetype)recordingWithData:(NSData *)data {
    if (![ANNotes loadFramework:NULL]) return nil;
    // Checked here rather than in loadFramework: without these only transcripts are missing.
    Class cls = NSClassFromString(@"ICTTAudioDocument");
    if (![cls respondsToSelector:@selector(registerWithICCRCoder)] || ![cls respondsToSelector:@selector(unarchiveFromData:replicaID:)]) return nil;
    for (NSString *selector in @[@"transcriptAsPlainText", @"recordingSummaryAsPlainText", @"topLineSummaryAsPlainText", @"isCallRecording"]) {
        if (![cls instancesRespondToSelector:NSSelectorFromString(selector)]) return nil;
    }
    static BOOL registered = NO;
    __block ANRecording *recording = nil;
    ANTry(@"reading a recording", NULL, ^{
        if (!registered) {
            [(id<ANAudioDocumentClass>)cls registerWithICCRCoder];
            registered = YES;
        }
        // The replica is who would make further changes; for reading any new one does.
        id<ANAudioDocument> document = [(id<ANAudioDocumentClass>)cls unarchiveFromData:data replicaID:[NSUUID UUID]];
        if (!document) return;
        recording = [[ANRecording alloc] initWithTranscript:ANPlain([document transcriptAsPlainText])
                                                    summary:ANPlain([document recordingSummaryAsPlainText])
                                                   headline:ANPlain([document topLineSummaryAsPlainText])
                                                       call:[document isCallRecording]];
    });
    return recording;
}

- (instancetype)initWithTranscript:(NSString *)transcript summary:(NSString *)summary headline:(NSString *)headline call:(BOOL)call {
    if (!(self = [super init])) return nil;
    _transcript = transcript;
    _summary = summary;
    _headline = headline;
    _call = call;
    return self;
}

@end

@implementation ANTableEdit {
    NSManagedObject *_attachment;
    id<ANTableModel> _model;
    id<ANTable> _table;
}

- (instancetype)initWithAttachment:(NSManagedObject *)attachment error:(NSError **)error {
    if (!(self = [super init])) return nil;
    if (![ANNotes sharedContext:error]) return nil;
    __block id model = nil, table = nil;
    if (!ANTry(@"opening a table", error, ^{
        model = [(id<ANSynced>)attachment attachmentModel];
        table = [(id<ANTableModel>)model table];
    })) return nil;
    if (!model || !table) {
        if (error) *error = ANError(@"the table attachment has no table");
        return nil;
    }
    _attachment = attachment;
    _model = model;
    _table = table;
    return self;
}

- (NSInteger)rowCount { return (NSInteger)[_table rowCount]; }
- (NSInteger)columnCount { return (NSInteger)[_table columnCount]; }

- (NSString *)textAtColumn:(NSInteger)column row:(NSInteger)row {
    __block NSString *text = @"";
    ANTry(@"reading a cell", NULL, ^{ text = ANPlain([self->_table stringForColumnIndex:(NSUInteger)column rowIndex:(NSUInteger)row]); });
    return text;
}

- (BOOL)insertRowAtIndex:(NSInteger)index error:(NSError **)error {
    return ANTry(@"adding a row", error, ^{ [self->_table insertRowAtIndex:(NSUInteger)index]; });
}

- (BOOL)removeRowAtIndex:(NSInteger)index error:(NSError **)error {
    return ANTry(@"removing a row", error, ^{ [self->_table removeRowAtIndex:(NSUInteger)index]; });
}

- (BOOL)insertColumnAtIndex:(NSInteger)index error:(NSError **)error {
    return ANTry(@"adding a column", error, ^{ [self->_table insertColumnAtIndex:(NSUInteger)index]; });
}

- (BOOL)removeColumnAtIndex:(NSInteger)index error:(NSError **)error {
    return ANTry(@"removing a column", error, ^{ [self->_table removeColumnAtIndex:(NSUInteger)index]; });
}

- (BOOL)replaceInColumn:(NSInteger)column row:(NSInteger)row range:(NSRange)range withText:(NSString *)text
                  style:(id)style error:(NSError **)error {
    return ANTry(@"editing a cell", error, ^{
        id columnID = [self->_table identifierForColumnAtIndex:(NSUInteger)column];
        id rowID = [self->_table identifierForRowAtIndex:(NSUInteger)row];
        id<ANMergeableString> cell = columnID && rowID ? [self->_table mergeableStringForColumnID:columnID rowID:rowID] : nil;
        NSString *current = ANPlain([self->_table stringForColumnIndex:(NSUInteger)column rowIndex:(NSUInteger)row]);
        if (!cell || current.length == 0) {
            NSAttributedString *whole = [[NSAttributedString alloc] initWithString:text attributes:@{@"TTStyle": style}];
            [self->_table setAttributedString:whole columnIndex:(NSUInteger)column rowIndex:(NSUInteger)row];
            return;
        }
        [cell beginEditing];
        @try {
            if (range.length > 0) [cell deleteCharactersInRange:range];
            if (text.length > 0) [cell insertString:text atIndex:range.location];
        } @finally {
            [cell endEditing];
        }
    });
}

- (BOOL)save:(NSError **)error {
    // Without the dirty flag the model writes nothing.
    return ANTry(@"saving a table", error, ^{
        [self->_model setMergeableDataDirty:YES];
        [self->_model writeMergeableData];
        [(id<ANSynced>)self->_attachment updateChangeCountWithReason:@"Edited table"];
    });
}

@end
