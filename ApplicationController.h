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

#import <Cocoa/Cocoa.h>
#import "GDataCalendar.h"

@class GDataServiceGoogleCalendar;

@interface ApplicationController : NSObject {
  IBOutlet NSWindow*             loginSheet_;
  IBOutlet NSTextField*          usernameField_;
  IBOutlet NSSecureTextField*    passwordField_;
  IBOutlet NSProgressIndicator*  loadingSpinner_;
  IBOutlet NSTextField*          loadingLabel_;
  IBOutlet NSButton*             loginButton_;

  IBOutlet NSWindow*             mainWindow_;
  IBOutlet NSWindow*             prefsWindow_;
  
  NSString*           username_;
  NSString*           password_;
  GDataServiceGoogleCalendar *contactsService_;
  
  NSMutableArray*     cals_;
}

- (IBAction)usernameChanged:(id)sender;
- (IBAction)login:(id)sender;
- (IBAction)quit:(id)sender;

- (IBAction)selectAll:(id)sender;
- (IBAction)deselectAll:(id)sender;
- (IBAction)setUpICal:(id)sender;

- (IBAction)openHelp:(id)sender;
- (IBAction)openKnownIssues:(id)sender;

@end
