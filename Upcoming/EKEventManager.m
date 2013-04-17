//
//  EKEventManager.m
//  EventKitTest
//
//  Created by Brendan Lynch on 13-04-11.
//  Copyright (c) 2013 Teehan+Lax. All rights reserved.
//

#import "EKEventManager.h"

NSString * const EKEventManagerAccessibleKeyPath = @"accessible";
NSString * const EKEventManagerEventsKeyPath = @"events";
NSString * const EKEventManagerNextEventKeyPath = @"nextEvent";
NSString * const EKEventManagerSourcesKeyPath = @"sources";

@interface EKEventManager ()

- (void)loadEvents;
- (void)resetSources;

@end

@implementation EKEventManager

- (id)init
{
	if (!(self = [super init]))
	{
		return nil;
	}
    
    _store = [[EKEventStore alloc] init];
    
    _sources = [[NSMutableArray alloc] initWithCapacity:0];
    _selectedCalendars = [[NSMutableArray alloc] initWithCapacity:0];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(storeChanged:)
                                                 name:EKEventStoreChangedNotification
                                               object:_store];

    if ([_store respondsToSelector:@selector(requestAccessToEntityType:completion:)]) {
        // iOS 6+ requires explicit user approval
        [_store requestAccessToEntityType:EKEntityTypeEvent
                               completion:^(BOOL granted, NSError *error) {
                                   [self willChangeValueForKey:EKEventManagerAccessibleKeyPath];
                                   _accessible = granted;
                                   [self didChangeValueForKey:EKEventManagerAccessibleKeyPath];
                                   
                                   if (_accessible) {
                                       // load events
                                       [self refresh];
                                   }
        }];
    } else {
        // prior to iOS 6, access is granted automatically
        [self willChangeValueForKey:EKEventManagerAccessibleKeyPath];
        _accessible = YES;
        [self didChangeValueForKey:EKEventManagerAccessibleKeyPath];
        
        [self refresh];
    }
	
	return self;
}

#pragma mark Public methods

+ (EKEventManager *)sharedInstance {
    static EKEventManager *_sharedInstance = nil;
    static dispatch_once_t pred;
    
    dispatch_once(&pred, ^{ _sharedInstance = [[self alloc] init]; });
    return _sharedInstance;
}

- (void)refresh {
    [self resetSources];
    [self loadEvents];
}

- (void)toggleCalendarWithIdentifier:(NSString *)calendarIdentifier {
    if ([_selectedCalendars containsObject:calendarIdentifier]) {
        [_selectedCalendars removeObject:calendarIdentifier];
    } else {
        [_selectedCalendars addObject:calendarIdentifier];
    }
    
    [[NSUserDefaults standardUserDefaults] setObject:[NSKeyedArchiver archivedDataWithRootObject:_selectedCalendars] forKey:@"SelectedCalendars"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    [self refresh];
}

#pragma mark Internal methods

- (void)storeChanged:(EKEventStore *)store {
    NSLog(@"STORE CHANGED.");
    [self refresh];
}

- (void)resetSources {
    [self willChangeValueForKey:EKEventManagerSourcesKeyPath];
    
    [_sources removeAllObjects];
    [_selectedCalendars removeAllObjects];
    
    BOOL hasCalendars = NO;
    NSUserDefaults *currentDefaults = [NSUserDefaults standardUserDefaults];
    NSData *dataRepresentingSavedArray = [currentDefaults objectForKey:@"SelectedCalendars"];
    if (dataRepresentingSavedArray != nil)
    {
        NSArray *oldSavedArray = [NSKeyedUnarchiver unarchiveObjectWithData:dataRepresentingSavedArray];
        if (oldSavedArray != nil) {
            [_selectedCalendars addObjectsFromArray:oldSavedArray];
            hasCalendars = YES;
        }
    }
    
    for (EKSource *source in [EKEventManager sharedInstance].store.sources)
    {
        NSSet *calendarSet = [source calendarsForEntityType:EKEntityTypeEvent];
        if ([calendarSet count] > 0) {
            [_sources addObject:source];
            if (!hasCalendars) {
                // load defaults
                NSArray *calendars = [calendarSet allObjects];
                for (EKCalendar *calendar in calendars) {
                    if (![_selectedCalendars containsObject:calendar.calendarIdentifier]) {
                        [_selectedCalendars addObject:calendar.calendarIdentifier];
                    }
                }
                
                // save them back to NSUserDefaults
                [[NSUserDefaults standardUserDefaults] setObject:[NSKeyedArchiver archivedDataWithRootObject:_selectedCalendars] forKey:@"SelectedCalendars"];
                [[NSUserDefaults standardUserDefaults] synchronize];
            }
        }
    }
    
    [self didChangeValueForKey:EKEventManagerSourcesKeyPath];
}

- (void)loadEvents {
    [self willChangeValueForKey:EKEventManagerEventsKeyPath];
    [_events removeAllObjects];
    [self didChangeValueForKey:EKEventManagerEventsKeyPath];
    
    [self willChangeValueForKey:EKEventManagerNextEventKeyPath];
    _nextEvent = nil;
    [self didChangeValueForKey:EKEventManagerNextEventKeyPath];
    
    // Get the appropriate calendar
    NSCalendar *calendar = [NSCalendar currentCalendar];
    
    NSMutableArray *calendars = nil;
    NSUserDefaults *currentDefaults = [NSUserDefaults standardUserDefaults];
    NSData *dataRepresentingSavedArray = [currentDefaults objectForKey:@"SelectedCalendars"];
    if (dataRepresentingSavedArray != nil) {
        NSArray *oldSavedArray = [NSKeyedUnarchiver unarchiveObjectWithData:dataRepresentingSavedArray];
        if (oldSavedArray != nil) {
            calendars = [[NSMutableArray alloc] initWithCapacity:0];
            for (NSString *identifier in oldSavedArray) {
                for (EKCalendar *calendarObject in [_store calendarsForEntityType:EKEntityTypeEvent]) {
                    if ([calendarObject.calendarIdentifier isEqualToString:identifier]) {
                        [calendars addObject:calendarObject];
                    }
                }
            }
        }
    }
    
    // no calendars selected. Empty views
    if (calendars == nil || [calendars count] == 0) {
        return;
    }
    
    NSUInteger unitFlags = NSYearCalendarUnit | NSMonthCalendarUnit |  NSDayCalendarUnit;
    
    // start date - midnight of current day
    NSDateComponents *midnightDate = [[NSDateComponents alloc] init];
    midnightDate = [calendar components:unitFlags fromDate:[NSDate date]];
    midnightDate.hour = 0;
    midnightDate.minute = 0;
    midnightDate.second = 0;
    NSDate *startDate = [calendar dateFromComponents:midnightDate];
    
    // end date - 11:59:59 of current day
    NSDateComponents *endComponents = [[NSDateComponents alloc] init];
    endComponents = [calendar components:unitFlags fromDate:[NSDate date]];
    endComponents.hour = 23;
    endComponents.minute = 59;
    endComponents.second = 59;
    NSDate *endDate = [calendar dateFromComponents:endComponents];
    
    // Create the predicate from the event store's instance method
    NSPredicate *predicate = [_store predicateForEventsWithStartDate:startDate
                                                             endDate:endDate
                                                           calendars:calendars];
    
    // get today's events
    [self willChangeValueForKey:EKEventManagerEventsKeyPath];
    _events = [NSMutableArray arrayWithArray:[_store eventsMatchingPredicate:predicate]];
    [_events sortUsingSelector:@selector(compareStartDateWithEvent:)];
    [self didChangeValueForKey:EKEventManagerEventsKeyPath];
    
    // find next event
    NSPredicate *nextPredicate = [_store predicateForEventsWithStartDate:endDate
                                                                 endDate:[NSDate distantFuture]
                                                               calendars:calendars];
    
    // Fetch all events that match the predicate
    NSMutableArray *nextEvents = [NSMutableArray array];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        [_store enumerateEventsMatchingPredicate:nextPredicate usingBlock:^(EKEvent *event, BOOL *stop) {
            if (event) {
                [nextEvents addObject:event];
            }
        }];
        [nextEvents sortUsingSelector:@selector(compareStartDateWithEvent:)];
        
        if ([nextEvents count] > 0) {
            [self willChangeValueForKey:EKEventManagerNextEventKeyPath];
            _nextEvent = nextEvents[0];
            [self didChangeValueForKey:EKEventManagerNextEventKeyPath];
        }
    });
}

#pragma mark Overriden methods

+ (BOOL)automaticallyNotifiesObserversForKey:(NSString *)key {
    BOOL automatic = NO;
    if ([key isEqualToString:EKEventManagerAccessibleKeyPath]) {
        automatic = NO;
    } else if ([key isEqualToString:EKEventManagerEventsKeyPath]) {
        automatic = NO;
    } else if ([key isEqualToString:EKEventManagerNextEventKeyPath]) {
        automatic = NO;
    } else if ([key isEqualToString:EKEventManagerSourcesKeyPath]) {
        automatic = NO;
    } else {
        automatic = [super automaticallyNotifiesObserversForKey: key];
    }
    
    return automatic;
}

@end