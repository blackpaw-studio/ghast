// Private CoreGraphics SPI for virtual displays, declared the way DeskPad does it.
// Dev-only: this tool is never shipped and runs only while a capture runs.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, retain) dispatch_queue_t queue;
@property (nonatomic, retain) NSString *name;
@property (nonatomic, assign) CGPoint bluePrimary;
@property (nonatomic, assign) CGPoint greenPrimary;
@property (nonatomic, assign) CGPoint redPrimary;
@property (nonatomic, assign) CGPoint whitePoint;
@property (nonatomic, assign) unsigned int maxPixelsHigh;
@property (nonatomic, assign) unsigned int maxPixelsWide;
@property (nonatomic, assign) CGSize sizeInMillimeters;
@property (nonatomic, assign) unsigned int serialNum;
@property (nonatomic, assign) unsigned int productID;
@property (nonatomic, assign) unsigned int vendorID;
@property (nonatomic, copy) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
@property (nonatomic, readonly) unsigned int width;
@property (nonatomic, readonly) unsigned int height;
@property (nonatomic, readonly) double refreshRate;
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, retain) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic, assign) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (nonatomic, readonly) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end
