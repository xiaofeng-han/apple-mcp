#import <Contacts/Contacts.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The private parts of Contacts.framework and AddressBook.framework that Apple Contacts MCP calls,
/// each one checked by runtime inspection and on this Mac's real store (macOS 27.2.1, Contacts 14.0;
/// see docs/RE-FINDINGS-contacts.md). Every method checks that the selector or class it needs is
/// there and answers with an error rather than crashing when it is not (another macOS version).
/// Validation (write guard, versions, names) is the caller's job; this layer only translates.
///
/// Notes are not here: Contacts.framework removes the note key from every fetch in a process
/// without Apple's notes entitlement, and any save of a card that has a note fails while it is
/// faulted for the search index. The Swift side reads and writes notes through Contacts.app's
/// AppleScript, and sets a card's note aside around a save.
@interface CSStore : NSObject

/// Lets a save change cards Screen Time allows during Downtime: Contacts.framework treats them as
/// read-only (CNErrorDomain 206) unless the save ignores guardian restrictions, as Contacts.app's own
/// saves do. The caller sets it only for such cards, and never in an account a guardian manages.
+ (void)allowDowntimeChangesInRequest:(CNSaveRequest *)request;
/// Whether a guardian (Screen Time for a child) manages this account's contacts; YES when this
/// version of macOS cannot tell, so that nothing a guardian limits is changed.
+ (BOOL)isGuardianRestrictedContainer:(CNContainer *)container;

/// Links two individual cards into one unified contact (both mutable copies of cards fetched with
/// unifyResults = NO and the "linkIdentifier" key). Several calls in one request make one group.
+ (BOOL)linkContact:(CNMutableContact *)contact toContact:(CNMutableContact *)other request:(CNSaveRequest *)request error:(NSError **)error;
/// Unlinks one card (an individual contact) from the others, or every card of a unified contact.
+ (BOOL)unlinkContact:(CNContact *)contact request:(CNSaveRequest *)request error:(NSError **)error;
/// Makes this card the My Card of its account (Contacts.app's Card > Make This My Card).
+ (BOOL)setMeCardIdentifier:(NSString *)identifier request:(CNSaveRequest *)request error:(NSError **)error;

/// Private setters on a mutable individual card. Each answers NO with an error when missing.
+ (BOOL)setPreferredForName:(BOOL)value contact:(CNMutableContact *)contact error:(NSError **)error;
+ (BOOL)setPreferredForImage:(BOOL)value contact:(CNMutableContact *)contact error:(NSError **)error;
/// Crop rectangle in the image's pixels, origin bottom left (Quartz), as Contacts stores it.
+ (BOOL)setCropRect:(CGRect)rect contact:(CNMutableContact *)contact error:(NSError **)error;
/// Clears the stored thumbnail, so a new photo or no photo replaces the old one at once.
+ (BOOL)clearThumbnailOfContact:(CNMutableContact *)contact error:(NSError **)error;
/// 0 default, 1 given name first, 2 family name first (Card > Reorder Last Name Before First).
+ (BOOL)setDisplayNameOrder:(NSInteger)order contact:(CNMutableContact *)contact error:(NSError **)error;
/// Screen Time: allowed to reach the user during Downtime.
+ (BOOL)setDowntimeAllowed:(BOOL)allowed contact:(CNMutableContact *)contact error:(NSError **)error;
/// Ringtone (call) or text tone (text): sound is a tone identifier ("system:<name>",
/// "texttone:<name>", "<default>", "<none>"); ignoreMute is Emergency Bypass. clear removes it.
+ (BOOL)setAlertForCalls:(BOOL)calls sound:(nullable NSString *)sound vibration:(nullable NSString *)vibration
              ignoreMute:(BOOL)ignoreMute clear:(BOOL)clear contact:(CNMutableContact *)contact error:(NSError **)error;
/// A card's alert as {sound, vibration, ignore_mute}, or nil when it has none.
+ (nullable NSDictionary<NSString *, id> *)alertForCalls:(BOOL)calls contact:(CNContact *)contact;

/// A restored card: a mutable copy of an archived card without its snapshot, so adding it keeps
/// its identifier (as Contacts.app's own undo of a delete does).
+ (nullable CNMutableContact *)restorableCopyOfContact:(CNContact *)contact error:(NSError **)error;
/// A parsed vCard contact without its note key, so it can be saved (the note is set afterwards
/// through AppleScript).
+ (nullable CNMutableContact *)copyOmittingNote:(CNContact *)contact error:(NSError **)error;
/// A copy of a fetched card that carries `note`, so vCard export can include it.
+ (nullable CNContact *)copyOfContact:(CNContact *)contact withNote:(NSString *)note error:(NSError **)error;

/// Contacts' own search: every word must appear somewhere in the card (names, company, phones,
/// emails, addresses, URLs, social profiles, related names, notes), case and diacritics ignored.
+ (nullable NSPredicate *)fullTextPredicateForText:(NSString *)text;
/// The My Card of every account.
+ (nullable NSPredicate *)meContactsPredicate;
/// The groups a card (fetched CNContact) belongs to, and their parents when asked.
+ (nullable NSPredicate *)groupsWithMemberContact:(CNContact *)contact parents:(BOOL)parents;
/// The groups a group is nested in.
+ (nullable NSPredicate *)groupsWithMemberGroup:(CNGroup *)group parents:(BOOL)parents;

/// Contacts' name settings as Contacts itself reads them (with their registered defaults):
/// {sort_by_first_name, family_name_first, short_names, short_name_format (0 full name, 1 first name and
/// last initial, 2 first initial and last name, 3 first name only, 4 last name only), prefer_nicknames,
/// country_code}; nil when ContactsFoundation is missing.
+ (nullable NSDictionary<NSString *, id> *)nameSettings;

/// vCard: version 3.0 (or 2.1), with or without photos and notes (notes must be in the contacts,
/// see copyOfContact:withNote:error:).
+ (nullable NSData *)vCardForContacts:(NSArray<CNContact *> *)contacts version21:(BOOL)version21 photos:(BOOL)photos
                                notes:(BOOL)notes error:(NSError **)error;

/// The current change-history token (an archived NSPersistentHistoryToken), and the changes since
/// one: [{kind: added|updated|deleted|linked|unlinked|preferred|me|group_added|group_updated|
/// group_deleted|member_added|member_removed|subgroup_added|subgroup_removed|everything, contact,
/// other, group, subgroup}] plus the new token; an event of another kind comes with its class name.
/// excludedAuthor leaves out saves this app made through Contacts.framework.
+ (nullable NSData *)currentHistoryTokenOfStore:(CNContactStore *)store;
+ (nullable NSDictionary<NSString *, id> *)changesInStore:(CNContactStore *)store since:(NSData *)token
                                           excludingAuthor:(nullable NSString *)author error:(NSError **)error;

@end

/// AddressBook.framework in this process: what Contacts.framework cannot do or does wrong here.
/// Records are found by their unique id, which is the Contacts identifier. (Removing a card from a
/// group goes through Contacts.app's AppleScript instead: CNSaveRequest -removeMember:fromGroup: is
/// a silent no-op on macOS 27, and an AddressBook save of a card that has a note fails.)
@interface CSAddressBook : NSObject

/// Links cards into one contact (Contacts' own linking, through a fresh AddressBook: a long-running
/// process's Contacts.framework refuses to link cards Contacts' sync agent has changed since it read
/// them, NSCocoaErrorDomain 134040). The first card gives the contact its name; photoCardID its photo.
+ (BOOL)linkCards:(NSArray<NSString *> *)cardIDs photoCard:(nullable NSString *)photoCardID error:(NSError **)error;
/// Takes one card out of its linked contact.
+ (BOOL)unlinkCard:(NSString *)cardID error:(NSError **)error;
/// Makes one linked card give the contact its name (or photo).
+ (BOOL)preferCard:(NSString *)cardID forName:(BOOL)name error:(NSError **)error;

/// Takes (CNSaveRequest -removeSubgroup:fromGroup: is a silent no-op too).
+ (BOOL)removeSubgroup:(NSString *)childID fromGroup:(NSString *)parentID error:(NSError **)error;

/// Smart lists (On My Mac only; Contacts keeps them in the local database and never syncs them):
/// [{id, name, highlight, criteria, members}]. criteria is the dictionary form below, decoded from
/// the stored search element; members are card ids.
+ (nullable NSArray<NSDictionary<NSString *, id> *> *)smartListsWithError:(NSError **)error;
/// Criteria: {match: all|any, rules: [{field, op, value}]}; the Swift side validates them first.
+ (nullable NSString *)createSmartList:(NSString *)name criteria:(NSDictionary<NSString *, id> *)criteria
                             highlight:(BOOL)highlight error:(NSError **)error;
+ (BOOL)updateSmartList:(NSString *)identifier name:(nullable NSString *)name criteria:(nullable NSDictionary<NSString *, id> *)criteria
              highlight:(nullable NSNumber *)highlight error:(NSError **)error;
+ (BOOL)deleteSmartList:(NSString *)identifier error:(NSError **)error;
/// The card ids matching criteria, without saving anything.
+ (nullable NSArray<NSString *> *)cardsMatchingCriteria:(NSDictionary<NSString *, id> *)criteria error:(NSError **)error;

/// Distribution list: which email, phone and address each member of a group uses:
/// [{card, email, phone, address}] where each is the chosen value's identifier, or absent for the
/// primary (first) one.
+ (nullable NSArray<NSDictionary<NSString *, id> *> *)distributionOfGroup:(NSString *)groupID error:(NSError **)error;
/// property: email, phone or address; valueID: the labeled value's identifier on that card.
+ (BOOL)setDistributionOfGroup:(NSString *)groupID card:(NSString *)cardID property:(NSString *)property
                         value:(NSString *)valueID error:(NSError **)error;

/// Accounts as Contacts.app shows them: [{id, name, type, default, can_be_default, main}].
+ (nullable NSArray<NSDictionary<NSString *, id> *> *)accountsWithError:(NSError **)error;
/// Makes an account (its AddressBook id, the container id without ":ABAccount") the default for new cards.
+ (BOOL)setDefaultAccount:(NSString *)accountID error:(NSError **)error;
/// Asks Contacts' sync agent to sync these accounts now (Refresh Accounts); does not wait.
+ (BOOL)syncAccounts:(NSArray<NSString *> *)accountIDs error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
