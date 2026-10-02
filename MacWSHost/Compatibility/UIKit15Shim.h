// UIKit15Shim.h -- compile-time shims exposing iOS 15/17 APIs against the
// iPhoneOS 14.5 SDK (the only complete SDK Theos ships).
//
// The device runs iPadOS 16.5, where the real classes/properties exist; these
// declarations only satisfy the compiler. All message dispatch stays dynamic,
// and the static-inline CAFrameRateRangeMake mirrors the system struct layout
// (three floats) so no QuartzCore link symbol is required.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - iOS 17 (private on 16.x): UIWindowScene activation options

typedef NS_ENUM(NSInteger, UIWindowScenePresentationStyle) {
    UIWindowScenePresentationStyleStandard  = 0,
    UIWindowScenePresentationStyleProminent = 1,
};

// Present as a private API on iOS 16.x (runtime-confirmed by upstream on
// 20D67); deliberately NOT tagged API_AVAILABLE(ios(17.0)) because the build
// uses -Werror -Wunguarded-availability-new and guards happen at runtime.
__attribute__((objc_runtime_visible))
@interface UIWindowSceneActivationRequestOptions : UISceneActivationRequestOptions
@property(nonatomic, assign) UIWindowScenePresentationStyle preferredPresentationStyle;
@end

#pragma mark - iOS 15: UIButtonConfiguration
// (UIBackgroundConfiguration itself exists in the 14.5 SDK; only the
// UIButtonConfiguration.background property is iOS 15.)

typedef NS_ENUM(NSInteger, UIButtonConfigurationCornerStyle) {
    UIButtonConfigurationCornerStyleFixed   = 0,
    UIButtonConfigurationCornerStyleCapsule = 1,
    UIButtonConfigurationCornerStyleLarge   = 2,
    UIButtonConfigurationCornerStyleMedium  = 3,
    UIButtonConfigurationCornerStyleSmall   = 4,
} API_AVAILABLE(ios(15.0));

API_AVAILABLE(ios(15.0))
__attribute__((objc_runtime_visible))
@interface UIButtonConfiguration : NSObject <NSCopying>
+ (UIButtonConfiguration *)plainButtonConfiguration;
+ (UIButtonConfiguration *)grayButtonConfiguration;
+ (UIButtonConfiguration *)tintedButtonConfiguration;
+ (UIButtonConfiguration *)filledButtonConfiguration;
@property(nullable, nonatomic, strong) UIColor *baseForegroundColor;
@property(nullable, nonatomic, strong) UIColor *baseBackgroundColor;
@property(nullable, nonatomic, copy) NSString *title;
@property(nullable, nonatomic, strong) UIImage *image;
@property(nullable, nonatomic, strong) UIImageSymbolConfiguration *preferredSymbolConfigurationForImage;
@property(nonatomic, assign) CGFloat imagePadding;
@property(nonatomic, assign) UIButtonConfigurationCornerStyle cornerStyle;
@property(nullable, nonatomic, copy) NSString *subtitle;
@property(nonatomic, assign) NSDirectionalEdgeInsets contentInsets;
@property(nullable, nonatomic, copy) NSDictionary *(^titleTextAttributesTransformer)(NSDictionary *attributes);
@property(nullable, nonatomic, strong) UIBackgroundConfiguration *background;
@end

@interface UIButton (MacWSiOS15Shim)
@property(nullable, nonatomic, strong) UIButtonConfiguration *configuration;
@property(nullable, nonatomic, copy) void (^configurationUpdateHandler)(UIButton *button);
@end

#pragma mark - iOS 15: UIColor system colors

@interface UIColor (MacWSiOS15Shim)
@property(class, nonatomic, strong, readonly) UIColor *systemCyanColor;
@end

#pragma mark - iOS 15: UIKeyCommand hardware keyboard additions

// iOS 15 added this input constant; value is the DEL codepoint. Both the
// registration site and the match site use this same symbol, so the shim is
// self-consistent even where it crosses the system boundary.
static NSString *const UIKeyInputDelete = @"\x7f";

@interface UIKeyCommand (MacWSiOS15Shim)
@property(nonatomic, assign) BOOL wantsPriorityOverSystemBehavior;
@end

#pragma mark - iOS 15: CADisplayLink frame rate range

typedef struct {
    float minimum;
    float maximum;
    float preferred;
} CAFrameRateRange;

static inline CAFrameRateRange CAFrameRateRangeMake(float minimum,
                                                    float maximum,
                                                    float preferred) {
    CAFrameRateRange range;
    range.minimum = minimum;
    range.maximum = maximum;
    range.preferred = preferred;
    return range;
}

@interface CADisplayLink (MacWSiOS15Shim)
@property(nonatomic, assign) CAFrameRateRange preferredFrameRateRange;
@end

NS_ASSUME_NONNULL_END
