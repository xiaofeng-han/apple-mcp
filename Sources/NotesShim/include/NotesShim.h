#import <CoreData/CoreData.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The part of Apple's private NotesShared framework this app uses, reached by name at run time:
/// linking the framework is refused ("not an allowed client"). Every call that reaches into
/// NotesShared catches Objective-C exceptions and returns them as NSError, so a macOS update that
/// changes a method fails one request instead of taking the server down.
@interface ANNotes : NSObject

/// Loads NotesShared and checks that every class and method used here exists.
+ (BOOL)loadFramework:(NSError **)error NS_SWIFT_NAME(loadFramework());

/// Notes' Core Data model, and the options Notes opens NoteStore.sqlite with.
+ (nullable NSManagedObjectModel *)managedObjectModel:(NSError **)error NS_SWIFT_NAME(managedObjectModel());
+ (nullable NSDictionary<NSString *, id> *)storeOptions:(NSError **)error NS_SWIFT_NAME(storeOptions());

/// Notes' own read-write context (ICNoteContext's shared context), started once per process.
/// Writes go through it, and table cells can only be read once it is running.
+ (nullable NSManagedObjectContext *)sharedContext:(NSError **)error NS_SWIFT_NAME(sharedContext());

/// `[object valueForKey:key]`, or nil when the object has no such key or raises.
+ (nullable id)valueForKey:(NSString *)key of:(id)object NS_SWIFT_NAME(value(forKey:of:));

/// A note's body as Notes keeps it, with Notes' own attributes (TTStyle, TTHints, NSAttachment…).
+ (nullable NSAttributedString *)bodyOfNote:(NSManagedObject *)note error:(NSError **)error NS_SWIFT_NAME(body(of:));

/// The cells of a table, as plain text by row. The marker is the NSAttachment value in a note
/// body; nil when the table cannot be read.
+ (nullable NSArray<NSArray<NSString *> *> *)rowsOfTableMarker:(id)marker context:(NSManagedObjectContext *)context
    NS_SWIFT_NAME(rowsOfTableMarker(_:context:));
+ (nullable NSArray<NSArray<NSString *> *> *)rowsOfTableAttachment:(NSManagedObject *)attachment NS_SWIFT_NAME(rowsOfTableAttachment(_:));

/// The record's iCloud state: its local version and the last version iCloud has.
+ (BOOL)cloudStateOf:(NSManagedObject *)object local:(NSInteger *)local synced:(NSInteger *)synced
    NS_SWIFT_NAME(cloudState(of:local:synced:));

/// A new empty note in a folder of the shared context.
+ (nullable NSManagedObject *)newNoteInFolder:(NSManagedObject *)folder error:(NSError **)error NS_SWIFT_NAME(newNote(inFolder:));

/// Marks an attachment (or another synced object) as deleted, the way Notes does.
+ (BOOL)markForDeletion:(NSManagedObject *)object error:(NSError **)error NS_SWIFT_NAME(mark(forDeletion:));

/// A paragraph style: Notes' style number (0 title … 103 checklist), indent and quote level.
/// `checked` is -1 for no checkbox, else 0 or 1. Copied from `existing` when given, so alignment
/// and writing direction carry over, and an existing checkbox keeps its identity.
+ (nullable id)paragraphStyle:(NSInteger)style indent:(NSInteger)indent quote:(NSInteger)quote checked:(NSInteger)checked
                      basedOn:(nullable id)existing error:(NSError **)error
    NS_SWIFT_NAME(paragraphStyle(_:indent:quote:checked:basedOn:));

/// A placeholder for an attachment in a note body (what NSAttachment holds).
+ (nullable id)attachmentMarkerWithID:(NSString *)identifier type:(NSString *)type NS_SWIFT_NAME(attachmentMarker(withID:type:));

/// The identifier and type of an attachment marker.
+ (nullable NSString *)markerID:(id)marker NS_SWIFT_NAME(markerID(_:));
+ (nullable NSString *)markerType:(id)marker NS_SWIFT_NAME(markerType(_:));

@end

/// One edit of a note body through its mergeable (CRDT) string. Every change is reported to the
/// note with NSTextStorage semantics, so its cached text and the saved data stay in step.
@interface ANBodyEdit : NSObject

- (nullable instancetype)initWithNote:(NSManagedObject *)note error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;

/// The body when the edit started. The mergeable string's own copy is a snapshot that only
/// changes at `end`, so callers keep their own mirror while editing.
@property (nonatomic, readonly) NSAttributedString *original;

- (BOOL)begin:(NSError **)error NS_SWIFT_NAME(begin());
- (BOOL)insert:(NSAttributedString *)text atIndex:(NSUInteger)index error:(NSError **)error NS_SWIFT_NAME(insert(_:at:));
- (BOOL)deleteRange:(NSRange)range error:(NSError **)error NS_SWIFT_NAME(deleteRange(_:));
- (BOOL)setAttributes:(NSDictionary<NSAttributedStringKey, id> *)attributes range:(NSRange)range error:(NSError **)error
    NS_SWIFT_NAME(setAttributes(_:range:));
/// Ends the editing session, dates the note now, and saves its data into the context.
- (BOOL)end:(NSError **)error NS_SWIFT_NAME(end());

/// Adds a table attachment to the note and returns its identifier. Cells are separated by tabs
/// and rows by newlines. Must be called outside begin/end: a table made inside an editing
/// session leaves the saved body cut short.
- (nullable NSString *)addTableWithText:(NSString *)text error:(NSError **)error NS_SWIFT_NAME(addTable(withText:));

@end

/// In-place changes to a table attachment. A table is a CRDT document of its own, so it is
/// edited outside the note body's editing session.
@interface ANTableEdit : NSObject

- (nullable instancetype)initWithAttachment:(NSManagedObject *)attachment error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSInteger rowCount;
@property (nonatomic, readonly) NSInteger columnCount;

- (NSString *)textAtColumn:(NSInteger)column row:(NSInteger)row NS_SWIFT_NAME(text(atColumn:row:));
- (BOOL)insertRowAtIndex:(NSInteger)index error:(NSError **)error NS_SWIFT_NAME(insertRow(at:));
- (BOOL)removeRowAtIndex:(NSInteger)index error:(NSError **)error NS_SWIFT_NAME(removeRow(at:));
- (BOOL)insertColumnAtIndex:(NSInteger)index error:(NSError **)error NS_SWIFT_NAME(insertColumn(at:));
- (BOOL)removeColumnAtIndex:(NSInteger)index error:(NSError **)error NS_SWIFT_NAME(removeColumn(at:));
/// Replaces `range` (UTF-16) of a cell's text with `text`, keeping the formatting of the rest.
/// A cell without text gets `text` with the given paragraph style instead.
- (BOOL)replaceInColumn:(NSInteger)column row:(NSInteger)row range:(NSRange)range withText:(NSString *)text
                  style:(id)style error:(NSError **)error NS_SWIFT_NAME(replace(inColumn:row:range:withText:style:));
/// Writes the table's data and tells Notes it changed, so it is uploaded.
- (BOOL)save:(NSError **)error NS_SWIFT_NAME(save());

@end

NS_ASSUME_NONNULL_END
