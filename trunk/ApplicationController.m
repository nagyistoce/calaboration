// Copyright 2008 Google Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not
// use this file except in compliance with the License.  You may obtain a copy
// of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
// WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
// License for the specific language governing permissions and limitations under
// the License.

#import <uuid/uuid.h>
#import <Security/Security.h>
#import <AddressBook/AddressBook.h>

#import "ApplicationController.h"

#import "GTMNSString+FindFolder.h"
#import "GTMNSFileManager+Path.h"

static NSString* const kPrefAllowReadOnlyCalConfigKey = @"AllowReadOnlyCalendarConfig";
static NSString* const kPrefAllowReadOnlyCalConfigValuesKey = @"values.AllowReadOnlyCalendarConfig";

static NSString* const kICalBundleId = @"com.apple.iCal";
static NSString* const kAddressBookBundleId = @"com.apple.AddressBook";

// keys in the calendar dictionary
static NSString* const kCalTitle          = @"title";
static NSString* const kCalID             = @"id";
static NSString* const kAlreadyConfigured = @"alreadyConfigured";
static NSString* const kShouldConfigure   = @"shouldConfigure";
static NSString* const kAccessLevel       = @"accessLevel";
static NSString* const kCanConfigure      = @"canConfigure";
static NSString* const kWritable          = @"writable";

// help pages
static NSString* const kHelpURI = @"http://www.google.com/support/calendar/bin/answer.py?answer=99355";
static NSString* const kKnownIssuesURI = @"http://www.google.com/support/calendar/bin/answer.py?answer=99360";

@interface ApplicationController (KeychainHelpers)
+ (SecAccessRef)createAccessPathToiCalLabed:(NSString *)label;
+ (BOOL)addInternetPassword:(NSString *)passwd
                    account:(NSString *)account
                     server:(NSString *)server
                      label:(NSString *)itemLabel
                       path:(NSString *)path
                   protocol:(SecProtocolType)protocol
                   authType:(SecAuthenticationType)authType
                       port:(int)port;
- (BOOL)setupKeychainFor:(NSString *)emailAddress;
@end


@interface ApplicationController ()
- (void)validateMeCard;
- (void)promptForLogin;
- (NSSet *)calendarIDsAlreadyConfigured;
- (BOOL)isICalRunning;

// GData call backs
- (void)calendarListFetchTicket:(GDataServiceTicket *)ticket
               finishedWithFeed:(GDataFeedCalendar *)feed;
- (void)calendarListFetchTicket:(GDataServiceTicket *)ticket
                failedWithError:(NSError *)error;
@end

// for turning access levels into icons
@interface GCalAccessLevelImageTransformer : NSValueTransformer
@end
// globals for the transformer
static NSSet *gReadWriteLevels;
static NSImage *gReadOnlyImage;

@implementation ApplicationController

+ (void)initialize {
  if (self == [ApplicationController class]) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *dict
      = [NSDictionary dictionaryWithObject:[NSNumber numberWithBool:NO]
                                    forKey:kPrefAllowReadOnlyCalConfigKey];
    if (dict) {
      [defaults registerDefaults:dict];
    }
  }
}

- (id)init {
  self = [super init];
  if (self) {
    cals_ = [[NSMutableArray alloc] init];

    // configure our GData server
    contactsService_ = [[GDataServiceGoogleCalendar alloc] init];
    [contactsService_ setServiceShouldFollowNextLinks:YES];
    NSArray *modes =
      [NSArray arrayWithObjects:NSDefaultRunLoopMode, NSModalPanelRunLoopMode,
         nil];  // just in case we ever add modals, we're already setup for it.
    [contactsService_ setRunLoopModes:modes];
    
    // register for pref notifications
    NSUserDefaultsController *defaults = [NSUserDefaultsController sharedUserDefaultsController];
    [defaults addObserver:self 
               forKeyPath:kPrefAllowReadOnlyCalConfigValuesKey
                  options:NSKeyValueObservingOptionNew
                  context:nil];
    
    if (!contactsService_) {
      [self release];
      self = nil;
    }
  }
  return self;
}

- (void)dealloc {
  NSUserDefaultsController *defaults = [NSUserDefaultsController sharedUserDefaultsController];
  [defaults removeObserver:self 
                forKeyPath:kPrefAllowReadOnlyCalConfigValuesKey];

  [username_ release];
  [password_ release];
  [contactsService_ release];
  [cals_ release];

  [super dealloc];
}

- (NSSet *)calendarIDsAlreadyConfigured {
  NSMutableSet *result = [NSMutableSet set];

  NSString *calDir = [NSString gtm_stringWithPathForFolder:kDomainLibraryFolderType
                                             subfolderName:@"Calendars"
                                                  inDomain:kUserDomain
                                                  doCreate:NO];
  if ([calDir length]) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *caldavDirs = [fm gtm_filePathsWithExtension:@"caldav"
                                             inDirectory:calDir];
    for (NSString *path in caldavDirs) {
      NSString *infoPlistPath = [path stringByAppendingPathComponent:@"Info.plist"];
      NSData *data = [NSData dataWithContentsOfFile:infoPlistPath];
      if ([data length] > 0) {
        NSDictionary *plist =
          [NSPropertyListSerialization propertyListFromData:data
                                           mutabilityOption:NSPropertyListImmutable
                                                     format:NULL
                                           errorDescription:NULL];
        if (plist) {
          NSString *calendarHomePath = [plist objectForKey:@"CalendarHomePath"];
          NSScanner *scanner = [NSScanner scannerWithString:calendarHomePath];
          NSString *calID;
          if ([scanner scanString:@"/calendar/dav/" intoString:NULL] &&
              [scanner scanUpToString:@"/" intoString:&calID] &&
              ([calID length] > 0)) {
            [result addObject:calID];
          }
        }
      }
    }
  }

  return result;
}

- (void)awakeFromNib {
  [loginButton_ setEnabled:NO];
  [mainWindow_ center];
}

- (void)applicationDidFinishLaunching:(NSNotification *)app {
  [self promptForLogin];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app {
  return YES;
}

- (void)validateMeCard {
  ABAddressBook* addressBook = [ABAddressBook addressBook];
  // If the address book isn't available, there's nothing we can do.
  if (!addressBook)
    return;
  ABPerson* meRecord = [addressBook me];

  // If there's no Me card at all, send them off to create one.
  if (!meRecord) {
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText:NSLocalizedString(@"MISSING_ME_CARD_MESSAGE", nil)];
    [alert setInformativeText:NSLocalizedString(@"MISSING_ME_CARD_INFO", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"CONTINUE_BUTTON", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"LAUNCH_ADDRESS_BOOK_BUTTON", nil)];
    NSInteger choice = [alert runModal];
    if (choice == NSAlertSecondButtonReturn) {
      [[NSWorkspace sharedWorkspace] launchAppWithBundleIdentifier:kAddressBookBundleId
                                                           options:NSWorkspaceLaunchDefault
                                    additionalEventParamDescriptor:nil
                                                  launchIdentifier:NULL];
      // We don't want to make this step blocking; assume they will do the
      // right thing and move on.
      return;
    }
  }

  // If there was a card, see if it has the email for this calendar account.
  ABMultiValue* emails = [meRecord valueForProperty:kABEmailProperty];
  BOOL containsCalenderEmail = NO;
  for (NSUInteger i = 0; i < [emails count]; ++i) {
    if ([[emails valueAtIndex:i] isEqualToString:username_]) {
      containsCalenderEmail = YES;
      break;
    }
  }
  // If it doesn't, offer to automatically add it.
  if (!containsCalenderEmail) {
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText:NSLocalizedString(@"MISSING_EMAIL_MESSAGE", nil)];
    [alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"MISSING_EMAIL_INFO_FORMAT", nil),
                                                         username_]];
    [alert addButtonWithTitle:NSLocalizedString(@"ADD_EMAIL_BUTTON", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"DONT_ADD_EMAIL_BUTTON", nil)];
    NSInteger choice = [alert runModal];
    if (choice == NSAlertFirstButtonReturn) {
      ABMutableMultiValue* mutableEmails = [emails mutableCopy];
      [mutableEmails addValue:username_ withLabel:kABEmailHomeLabel];
      [meRecord setValue:mutableEmails forProperty:kABEmailProperty];
      [addressBook save];
    }
  }
}

- (void)promptForLogin {
  [loadingSpinner_ stopAnimation:nil];
  [loadingLabel_ setHidden:YES];
  [loginButton_ setEnabled:([[usernameField_ stringValue] length] > 0)];

  // If we are re-prompting, the sheet is still up.
  if (![mainWindow_ attachedSheet]) {
    [NSApp beginSheet:loginSheet_
       modalForWindow:mainWindow_
        modalDelegate:self
       didEndSelector:nil
          contextInfo:nil];
  }
}

- (void)fetchCalendarList {
  [loginButton_ setEnabled:NO];
  [loadingSpinner_ startAnimation:nil];
  [loadingLabel_ setHidden:NO];

  [contactsService_ setUserCredentialsWithUsername:username_
                                          password:password_];

  [contactsService_ fetchCalendarFeedWithURL:[NSURL URLWithString:kGDataGoogleCalendarDefaultAllCalendarsFeed ]
                                    delegate:self
                           didFinishSelector:@selector(calendarListFetchTicket:finishedWithFeed:)
                             didFailSelector:@selector(calendarListFetchTicket:failedWithError:)];
}

- (void)calendarListFetchTicket:(GDataServiceTicket *)ticket
               finishedWithFeed:(GDataFeedCalendar *)feed {
  BOOL allowReadOnlyConfig
    = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefAllowReadOnlyCalConfigKey];
  // build up the list of calendars
  NSMutableArray *ownedCals = [NSMutableArray array];
  NSMutableArray *otherCals = [NSMutableArray array];
  NSSet *configuredCals = [self calendarIDsAlreadyConfigured];
  NSArray *entries = [feed entries];
  for (GDataEntryCalendar *calendar in entries) {
    NSScanner *scanner = [NSScanner scannerWithString:[calendar identifier]];
    NSString *calID;
    // GData for calendar doesn't vend the IDs in any useful way, so we have to
    // use knowledge of the urls to scan it and get the actual ids off the end.
    if ([scanner scanString:kGDataGoogleCalendarDefaultAllCalendarsFeed
                 intoString:NULL] &&
        [scanner scanString:@"/" intoString:NULL] &&
        [scanner scanUpToString:@"\n" intoString:&calID] && // use \n to get the rest
        ([calID length] > 0)) {
      // is it already configured?
      BOOL alreadyConfigured = [configuredCals containsObject:calID];
      NSString *accessLevel = [[calendar accessLevel] stringValue];
      BOOL isWritable = [accessLevel isEqualTo:kGDataCalendarAccessOwner] ||
                        [accessLevel isEqualTo:kGDataCalendarAccessEditor] ||
                        [accessLevel isEqualTo:kGDataCalendarAccessContributor];
      // iCal doesn't currently check the permissions on calendars accessed via
      // CalDAV, it just assumes they are all editable.  if you only have R/O
      // access iCal will let you make changes/additions and then it will put up
      // errors when it can't push them back to the CalDAV server and the data
      // can get out of sync between the local copy and the server.  so we use
      // a pref to see if we should allow those to be configured.
      // Also lock down anything already in iCal, since we can't remove calendars.
      BOOL canConfigure
        = (isWritable || allowReadOnlyConfig) && !alreadyConfigured;
      // If it's already configured, it gets checked, otherwise it gets checked
      // only if it is checked in the gCal ui and you have write access to it.
      BOOL shouldCheck =
        (alreadyConfigured ? YES : ( isWritable ? [calendar isSelected] : NO ) );
      // mutable so the UI can change the kShouldConfigure flag
      NSMutableDictionary *calDict =
        [NSMutableDictionary dictionaryWithObjectsAndKeys:
          calID, kCalID,
          [NSNumber numberWithBool:isWritable], kWritable,
          [NSNumber numberWithBool:alreadyConfigured], kAlreadyConfigured,
          [NSNumber numberWithBool:shouldCheck], kShouldConfigure,
          [NSNumber numberWithBool:canConfigure], kCanConfigure,
          [[calendar accessLevel] stringValue], kAccessLevel,
          [[calendar title] stringValue], kCalTitle,
          nil];
      if ([accessLevel isEqualTo:kGDataCalendarAccessOwner]) {
        [ownedCals addObject:calDict];
      } else {
        [otherCals addObject:calDict];
      }
    }
  }

  // Sort read-only calendars to the bottom since we can't currently do anything
  // with them. We keep owned calendars separate until after the sort so that
  // we don't change their order (keeping the primary calendar first).
  [otherCals sortUsingDescriptors:[NSArray arrayWithObjects:
                                   [[[NSSortDescriptor alloc] initWithKey:kWritable
                                                                ascending:NO] autorelease],
                                   [[[NSSortDescriptor alloc] initWithKey:kCalTitle
                                                                ascending:YES
                                                                 selector:@selector(caseInsensitiveCompare:)] autorelease],
                                   nil]];

  // swap the list in
  [self willChangeValueForKey:@"cals_"];
  [cals_ removeAllObjects];
  [cals_ addObjectsFromArray:ownedCals];
  [cals_ addObjectsFromArray:otherCals];
  [self didChangeValueForKey:@"cals_"];

  // dismiss the login sheet
  [NSApp endSheet:loginSheet_];
  [loginSheet_ orderOut:nil];
}

- (void)calendarListFetchTicket:(GDataServiceTicket *)ticket
                failedWithError:(NSError *)error {

  NSAlert *alert;
  // check for 403 as a sepecial case..means a password mismatch
  if ([error code] == 403) {
    alert = [NSAlert alertWithMessageText:NSLocalizedString(@"AUTH_FAIL_MESSAGE", nil)
                            defaultButton:nil
                          alternateButton:nil
                              otherButton:nil
                informativeTextWithFormat:NSLocalizedString(@"AUTH_FAIL_INFO", nil)];
  } else {
    alert = [NSAlert alertWithError:error];
  }
  [alert runModal];
  [self promptForLogin];
}

- (void)setAll:(BOOL)value {
  for (NSDictionary *dict in cals_) {
    // only toggle the ones that we can configure this time.
    if ([[dict objectForKey:kCanConfigure] boolValue]) {
      [dict setValue:[NSNumber numberWithBool:value] forKey:kShouldConfigure];
    }
  }
}

- (IBAction)selectAll:(id)sender {
  [self setAll:YES];
}

- (IBAction)deselectAll:(id)sender {
  [self setAll:NO];
}

- (int)createCalendarAcctNamed:(NSString*)name withID:(NSString*)ident {
  // This shouldn't actually happen, but check just in case.
  if ([[self calendarIDsAlreadyConfigured] containsObject:ident]) {
    return 0;
  }

  uuid_t uuid_binary;
  uuid_generate(uuid_binary);
  char uuid_cstr[37];
  uuid_unparse_upper(uuid_binary, uuid_cstr);
  NSString *uuid = [NSString stringWithCString:uuid_cstr encoding:NSASCIIStringEncoding];

  NSString *calDirPath = [NSString gtm_stringWithPathForFolder:kDomainLibraryFolderType
                                                 subfolderName:@"Calendars"
                                                      inDomain:kUserDomain
                                                      doCreate:NO];
  NSString *davDirPath = [calDirPath stringByAppendingPathComponent:[uuid stringByAppendingString:@".caldav"]];

  BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:davDirPath
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:NULL];
  if (ok) {
    NSString *templatePath =
      [[NSBundle mainBundle] pathForResource:@"template" ofType:@"plist"];
    NSString *encodedIdent =
      [ident stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    NSMutableString *template =
      [NSMutableString stringWithContentsOfFile:templatePath
                                       encoding:NSUTF8StringEncoding
                                          error:NULL];
    [template replaceOccurrencesOfString:@"{{UUID}}"
                              withString:uuid
                                 options:NSLiteralSearch
                                   range:NSMakeRange(0, [template length])];
    [template replaceOccurrencesOfString:@"{{NAME}}"
                              withString:name
                                 options:NSLiteralSearch
                                   range:NSMakeRange(0, [template length])];
    
    [template replaceOccurrencesOfString:@"{{ENCODED_EMAIL}}"
                              withString:ident
                                 options:NSLiteralSearch
                                   range:NSMakeRange(0, [template length])];
    
    [template replaceOccurrencesOfString:@"{{EMAIL}}"
                              withString:encodedIdent
                                 options:NSLiteralSearch
                                   range:NSMakeRange(0, [template length])];
    
    [template replaceOccurrencesOfString:@"{{LOGIN}}"
                              withString:username_
                                 options:NSLiteralSearch
                                   range:NSMakeRange(0, [template length])];
    
    ok = [template writeToFile:[davDirPath stringByAppendingPathComponent:@"Info.plist"]
                    atomically:YES
                      encoding:NSUTF8StringEncoding
                         error:NULL];
    if (ok && [self setupKeychainFor:encodedIdent]) {
      return  1;
    }
  }

  return -1;
}

- (BOOL)isICalRunning {
  NSArray *apps = [[NSWorkspace sharedWorkspace] launchedApplications];
  NSArray *appNames = [apps valueForKey:@"NSApplicationBundleIdentifier"];
  return [appNames containsObject:kICalBundleId];
}

- (IBAction)setUpICal:(id)sender {
  // make sure iCal isn't running before changing files
  while ([self isICalRunning]) {
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText:NSLocalizedString(@"QUIT_ICAL_MESSAGE", nil)];
    [alert setInformativeText:NSLocalizedString(@"QUIT_ICAL_INFO", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"CONTINUE_BUTTON", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"CANCEL_BUTTON", nil)];

    NSInteger choice = [alert runModal];
    if (choice == NSAlertSecondButtonReturn)
      return;
  }

  BOOL changediCal = NO;
  NSMutableArray* failedCalendars = [NSMutableArray array];
  for (NSDictionary *dict in cals_) {
    if (![[dict objectForKey:kAlreadyConfigured] boolValue] &&
        [[dict objectForKey:kShouldConfigure] boolValue]) {
      NSString *name = [dict objectForKey:kCalTitle];
      NSString *ident = [dict objectForKey:kCalID];

      int result = [self createCalendarAcctNamed:name withID:ident];
      if (result < 0) {
        [failedCalendars addObject:name];
      } else if (result > 0) {
        changediCal = YES;
      }
    }
  }

  if ([failedCalendars count] > 0) {
    NSAlert *failureAlert = [[[NSAlert alloc] init] autorelease];
    [failureAlert setMessageText:NSLocalizedString(@"CALENDAR_ADD_ERROR_MESSAGE", nil)];
    [failureAlert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"CALENDAR_ADD_ERROR_INFO_FORMAT", nil),
                                      [failedCalendars componentsJoinedByString:@", "]]];
    [failureAlert runModal];
  }

  if (changediCal) {
    NSString *calDirPath = [NSString gtm_stringWithPathForFolder:kDomainLibraryFolderType
                                                   subfolderName:@"Calendars"
                                                        inDomain:kUserDomain
                                                        doCreate:NO];
    NSString *cachePath = [calDirPath stringByAppendingPathComponent:@"Calendar Cache"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:cachePath] &&
        [fm removeItemAtPath:cachePath error:NULL] == NO) {
      NSAlert *alert = [[[NSAlert alloc] init] autorelease];
      [alert setMessageText:NSLocalizedString(@"SETUP_ERROR_MESSAGE", nil)];
      [alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"CALENDAR_ADD_ERROR_INFO_FORMAT", nil),
                                 cachePath]];

      [alert runModal];
    } else {
      // Now that we know we actually accomplished something, check that there's
      // a Me card set up in Address Book with the account's email address.
      [self validateMeCard];

      NSAlert *alert = [[[NSAlert alloc] init] autorelease];
      [alert setMessageText:NSLocalizedString(@"SUCCESS_MESSAGE", nil)];
      [alert setInformativeText:NSLocalizedString(@"SUCCESS_INFO", nil)];
      [alert addButtonWithTitle:NSLocalizedString(@"LAUNCH_ICAL_BUTTON", nil)];
      [alert addButtonWithTitle:NSLocalizedString(@"QUIT_BUTTON", nil)];
      NSInteger choice = [alert runModal];
      if (choice == NSAlertFirstButtonReturn) {
        [[NSWorkspace sharedWorkspace] launchAppWithBundleIdentifier:kICalBundleId
                                                             options:NSWorkspaceLaunchDefault
                                      additionalEventParamDescriptor:nil
                                                    launchIdentifier:NULL];
      }
    }
    // Quit either way.
    [[NSApplication sharedApplication] terminate:self];
  } else if ([failedCalendars count] == 0) {
    // If there were no additions and no failures, give them a dialog so they
    // get some kind of feedback from pressing the button.
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText:NSLocalizedString(@"NO_CHANGE_MESSAGE", nil)];
    [alert setInformativeText:NSLocalizedString(@"NO_CHANGE_INFO", nil)];
    [alert runModal];
  }
}

// Called when the user finishes editing their username.
- (IBAction)usernameChanged:(id)sender {
  NSString *username = [usernameField_ stringValue];

  NSCharacterSet *whitespaceSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];
  username = [username stringByTrimmingCharactersInSet:whitespaceSet];

  // If no domain was supplied, add @gmail.com
  if ([username length] > 0 &&
      [username rangeOfString:@"@"].location == NSNotFound)
    username = [username stringByAppendingString:@"@gmail.com"];

  if (![username isEqualToString:[usernameField_ stringValue]])
    [usernameField_ setStringValue:username];
}

// Called as typing happens in the username and password fields.
- (void)controlTextDidChange:(NSNotification *)aNotification {
  [loginButton_ setEnabled:([[usernameField_ stringValue] length] > 0 &&
                            [[passwordField_ stringValue] length] > 0)];
}

- (IBAction)login:(id)sender {
  NSString *newUsername = [usernameField_ stringValue];
  NSString *newPassword = [passwordField_ stringValue];

  [username_ release];
  username_ = [newUsername retain];
  [password_ release];
  password_ = [newPassword retain];

  [self fetchCalendarList];
}

- (IBAction)quit:(id)sender {
  [NSApp endSheet:loginSheet_];
  [NSApp terminate:nil];
}

- (IBAction)openHelp:(id)sender {
  [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:kHelpURI]];
}

- (IBAction)openKnownIssues:(id)sender {
  [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:kKnownIssuesURI]];
}

- (void)observeValueForKeyPath:(NSString *)keyPath 
                      ofObject:(id)object 
                        change:(NSDictionary *)change 
                       context:(void *)context {
  if ([object isEqualTo:[NSUserDefaultsController sharedUserDefaultsController]]
      && [keyPath isEqualToString:kPrefAllowReadOnlyCalConfigValuesKey]) {
    // this must stay in sync w/ -calendarListFetchTicket:finishedWithFeed: for
    // some of the logic.
    [self willChangeValueForKey:@"cals_"];
    // update the the r/o ones
    BOOL allowReadOnlyConfig
      = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefAllowReadOnlyCalConfigKey];
    for (NSMutableDictionary *calDict in cals_) {
      BOOL isWritable = [[calDict objectForKey:kWritable] boolValue];
      BOOL alreadyConfigured = [[calDict objectForKey:kAlreadyConfigured] boolValue];
      if (!isWritable && !alreadyConfigured) {
        // set the can configure based on the new pref value
        [calDict setObject:[NSNumber numberWithBool:allowReadOnlyConfig]
                    forKey:kCanConfigure];
        if (!allowReadOnlyConfig) {
          // don't allow readonly config, clear the should configure flags
          [calDict setObject:[NSNumber numberWithBool:NO]
                      forKey:kShouldConfigure];
        }
      }
    }
    [self didChangeValueForKey:@"cals_"];
  }
}  

@end

@implementation ApplicationController (KeychainHelpers)

+ (SecAccessRef)createAccessPathToiCalLabed:(NSString *)label {

  // If iCal isn't in its default spot, go find it. (We avoid the find if we can
  // since LaunchServices sometimes likes to find things on a non-boot drive.)
  #define kICalPathDefault "/Applications/iCal.app"
  #define kICalPathDefaultStr @ kICalPathDefault
  static NSString *iCalPath = nil;
  if (!iCalPath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:kICalPathDefaultStr]) {
      iCalPath = kICalPathDefaultStr;
    } else {
      CFURLRef urlRef = NULL;
      if (LSFindApplicationForInfo(kLSUnknownCreator,
                                   CFSTR("com.apple.iCal"),
                                   NULL, 
                                   NULL,
                                   &urlRef) == noErr) {
        iCalPath = [[(NSURL*)urlRef path] retain];
        CFRelease(urlRef);
      }
    }
  }
  
  const char* iCalCStrPath;
  if (iCalPath) {
    iCalCStrPath = [iCalPath UTF8String];
  }
  if (!iCalCStrPath) {
    iCalCStrPath = kICalPathDefault;
  }

  SecTrustedApplicationRef myself, iCal;
  if ((SecTrustedApplicationCreateFromPath(NULL, &myself) == noErr) &&
      (SecTrustedApplicationCreateFromPath(iCalCStrPath, &iCal) == noErr)) {

    NSArray *trustedApps = [NSArray arrayWithObjects:(id)myself, (id)iCal, nil];

    SecAccessRef accessRef = NULL;
    if (SecAccessCreate((CFStringRef)label,(CFArrayRef)trustedApps,
                        &accessRef) == noErr) {
      return accessRef;
    }
  }

  return nil;
}

+ (BOOL)addInternetPassword:(NSString *)passwd
                    account:(NSString *)account
                     server:(NSString *)server
                      label:(NSString *)itemLabel
                       path:(NSString *)path
                   protocol:(SecProtocolType)protocol
                   authType:(SecAuthenticationType)authType
                       port:(int)port {

  const char *pathUTF8 = [path UTF8String];
  const char *serverUTF8 = [server UTF8String];
  const char *accountUTF8 = [account UTF8String];
  const char *passwdUTF8 = [passwd UTF8String];
  const char *itemLabelUTF8 = [itemLabel UTF8String];
  SecKeychainAttribute attrs[] = {
    { kSecLabelItemAttr,    (UInt32)strlen(itemLabelUTF8),   (char *)itemLabelUTF8 },
    { kSecAccountItemAttr,  (UInt32)strlen(accountUTF8),     (char *)accountUTF8 },
    { kSecServerItemAttr,   (UInt32)strlen(serverUTF8),      (char *)serverUTF8 },
    { kSecPortItemAttr,     (UInt32)sizeof(int),             (int *)&port },
    { kSecPathItemAttr,     (UInt32)strlen(pathUTF8),        (char *)pathUTF8 },
    { kSecProtocolItemAttr, (UInt32)sizeof(SecProtocolType), &protocol },
    { kSecAuthenticationTypeItemAttr, (UInt32)sizeof(SecAuthenticationType), &authType },
  };
  SecKeychainAttributeList attributes =
    { (UInt32)(sizeof(attrs) / sizeof(attrs[0])), attrs };

  SecAccessRef accessRef = [self createAccessPathToiCalLabed:itemLabel];

  BOOL succeeded = NO;
  if (accessRef) {
    OSErr err =
      SecKeychainItemCreateFromContent(kSecInternetPasswordItemClass,
                                       &attributes,
                                       (UInt32)strlen(passwdUTF8),
                                       passwdUTF8,
                                       NULL, // use the default keychain
                                       accessRef,
                                       NULL);
    succeeded = (err == noErr) || (err == errKCDuplicateItem);
    CFRelease(accessRef);
  }

  return succeeded;
}

- (BOOL)setupKeychainFor:(NSString *)emailAddress {

  NSRange split = [username_ rangeOfString:@"@" options:NSBackwardsSearch];
  if (split.location == NSNotFound) {
    return NO;
  }
  NSString *user = [username_ substringToIndex: split.location];
  NSString *domain = [username_ substringFromIndex: split.location+1];

  if (![user length] || ![domain length] || ![emailAddress length]) {
    return NO;
  }

  NSString *serverName = [NSString stringWithFormat:@"%@@www.google.com", domain];
  NSString *resource = [NSString stringWithFormat:@"/calendar/dav/%@/user/",emailAddress];

  return [[self class] addInternetPassword:password_
                                   account:user
                                    server:serverName
                                     label:serverName
                                      path:resource
                                  protocol:kSecProtocolTypeHTTPS
                                  authType:kSecAuthenticationTypeDefault
                                      port:0];
}

@end

@implementation GCalAccessLevelImageTransformer

+ (void)initialize {
  // setup some globals for us
  gReadWriteLevels = [[NSSet alloc] initWithObjects:kGDataCalendarAccessEditor,
                                                    kGDataCalendarAccessOwner,
                                                    kGDataCalendarAccessContributor,
                                                    nil];
  gReadOnlyImage = [[NSImage imageNamed:NSImageNameLockLockedTemplate] retain];
}

+ (Class)transformedValueClass {
  return [NSImage class];
}

+ (BOOL)allowsReverseTransformation {
  return NO;
}

- (id)transformedValue:(id)value {
  NSImage *result = nil;

  if ([value isKindOfClass:[NSString class]]) {
    NSString *accessLevel = (NSString *)value;
    // we default to readonly icon, so we just test for the ones we want to
    // clear the value for.
    if ([gReadWriteLevels containsObject:accessLevel]) {
      result = nil;
    } else {
      result = gReadOnlyImage;
    }
  }

  return result;
}

@end
