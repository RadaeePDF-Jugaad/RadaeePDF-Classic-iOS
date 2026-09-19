//
//  UIView+RDGlass.m
//  PDFViewer
//

#import "UIView+RDGlass.h"
#import <QuartzCore/QuartzCore.h>

@implementation UIView (RDGlass)

- (UIVisualEffectView *)rd_applyGlassBackgroundWithCornerRadius:(CGFloat)cornerRadius
{
    UIVisualEffect *effect;
    if (@available(iOS 26.0, *)) {
        effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    } else {
        effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    }

    UIVisualEffectView *effectView = [[UIVisualEffectView alloc] initWithEffect:effect];
    effectView.frame = self.bounds;
    effectView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    effectView.layer.cornerRadius = cornerRadius;
    effectView.layer.cornerCurve = kCACornerCurveContinuous;
    effectView.clipsToBounds = YES;
    effectView.userInteractionEnabled = NO;
    [self insertSubview:effectView atIndex:0];

    self.backgroundColor = [UIColor clearColor];

    return effectView;
}

@end
