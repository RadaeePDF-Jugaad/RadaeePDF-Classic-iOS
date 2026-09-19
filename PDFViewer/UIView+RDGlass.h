//
//  UIView+RDGlass.h
//  PDFViewer
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface UIView (RDGlass)

/// Inserts a rounded system glass/material background behind the view's
/// existing content (UIGlassEffect on iOS 26+, UIBlurEffect systemMaterial
/// otherwise) and clears the view's own backgroundColor. Returns the
/// inserted UIVisualEffectView.
- (UIVisualEffectView *)rd_applyGlassBackgroundWithCornerRadius:(CGFloat)cornerRadius;

@end

NS_ASSUME_NONNULL_END
