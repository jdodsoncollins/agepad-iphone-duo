#ifndef AGE_PAD_TOUCH_COMMAND_WHEEL_H
#define AGE_PAD_TOUCH_COMMAND_WHEEL_H

/* Portable layout and selection rules shared by the UIKit wheel and tests.
 * Coordinates are view points: positive x right, positive y down. */
#include <math.h>

typedef enum DECommandWheelAction {
    DECommandWheelNone = -1,
    DECommandWheelOrder = 0,
    DECommandWheelIdle,
    DECommandWheelTown,
    DECommandWheelZoomIn,
    DECommandWheelZoomOut,
    DECommandWheelMenu,
    DECommandWheelActionCount
} DECommandWheelAction;

static const double DECommandWheelHoldDuration = 0.45;
static const double DECommandWheelMinimumRadius = 90.0;

/* Use the space available to the game host, including narrow/resized iPad
 * windows. Hardware idiom alone does not describe the available space. */
static inline int DEUseCompactControls(double width, double height) {
    return !isfinite(width) || !isfinite(height) || width < 600.0 || height < 520.0;
}

/* Twelve points of margin on each side. A caller should not present the
 * wheel below MinimumRadius; selection is disabled there as a second guard. */
static inline double DETouchWheelRadiusForBounds(double width, double height) {
    if (!isfinite(width) || !isfinite(height)) return 0.0;
    return fmax(0.0, fmin(108.0, (fmin(width, height) - 24.0) / 2.0));
}

/* Six equal sectors, centered at the top and proceeding clockwise. The
 * center and an excursion beyond the outer tolerance both cancel. This is
 * stateless: moving back into a sector reselects it after either excursion. */
static inline DECommandWheelAction DEWheelActionForOffset(double dx, double dy, double radius) {
    if (!isfinite(dx) || !isfinite(dy) || !isfinite(radius) ||
        radius < DECommandWheelMinimumRadius) return DECommandWheelNone;
    double distance = hypot(dx, dy);
    if (distance < fmax(28.0, radius * 0.26) || distance > radius + 36.0)
        return DECommandWheelNone;
    const double pi = 3.14159265358979323846;
    double angle = atan2(dx, -dy);
    if (angle < 0.0) angle += 2.0 * pi;
    int sector = (int)floor((angle + pi / 6.0) / (pi / 3.0));
    return (DECommandWheelAction)(sector % DECommandWheelActionCount);
}

static inline double DEClampWheelAxis(double value, double minimum, double maximum, double radius) {
    /* Host safe-area rectangles use nonnegative local coordinates. Treat an
     * empty/inverted rectangle as a collapsed interval, rather than creating
     * a negative center when its diameter cannot fit. */
    minimum = isfinite(minimum) ? fmax(0.0, minimum) : 0.0;
    maximum = isfinite(maximum) ? fmax(minimum, maximum) : minimum;
    if (!isfinite(value)) value = minimum + (maximum - minimum) / 2.0;
    radius = isfinite(radius) ? fmax(0.0, radius) : 0.0;
    if (maximum - minimum < radius * 2.0)
        return minimum + (maximum - minimum) / 2.0;
    return fmax(minimum + radius, fmin(maximum - radius, value));
}

/* Clamp the drawn wheel, not its game-command target. If a dimension cannot
 * fit the wheel, center it in that dimension; the radius/availability guard
 * above lets the caller choose a compact fallback instead. */
static inline void DEClampWheelCenter(double x, double y,
                                     double minX, double minY, double maxX, double maxY,
                                     double radius, double *outX, double *outY) {
    if (outX) *outX = DEClampWheelAxis(x, minX, maxX, radius);
    if (outY) *outY = DEClampWheelAxis(y, minY, maxY, radius);
}

#endif
