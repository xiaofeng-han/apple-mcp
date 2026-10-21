#import "NotesShim.h"

#import <dlfcn.h>
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

@protocol ANSynced
- (id)cloudState;
- (void)markForDeletion;
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
