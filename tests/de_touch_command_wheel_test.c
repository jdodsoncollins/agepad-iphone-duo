/* Production wheel geometry, without UIKit or any game assets.
 * Run: cc -std=c11 -Wall -Wextra -Werror -pedantic -I port/de \
 *      tests/de_touch_command_wheel_test.c -lm -o /tmp/agepad-wheel-test
 *      /tmp/agepad-wheel-test */
#include "TouchCommandWheel.h"
#include <assert.h>
#include <stdio.h>

static void near(double actual, double expected) {
    assert(fabs(actual - expected) < 0.000001);
}

static DECommandWheelAction at_angle(double radians, double distance, double radius) {
    return DEWheelActionForOffset(sin(radians) * distance, -cos(radians) * distance, radius);
}

int main(void) {
    const double pi = 3.14159265358979323846;
    assert(DEUseCompactControls(852, 393));
    assert(DEUseCompactControls(393, 852));
    assert(DEUseCompactControls(599.99, 1024));
    assert(DEUseCompactControls(1024, 519.99));
    assert(!DEUseCompactControls(600, 520));
    assert(!DEUseCompactControls(1366, 1024));
    assert(DEUseCompactControls(NAN, 1024));

    near(DECommandWheelHoldDuration, 0.45);
    near(DETouchWheelRadiusForBounds(852, 393), 108);
    near(DETouchWheelRadiusForBounds(240, 240), 108);
    near(DETouchWheelRadiusForBounds(204, 852), 90);
    near(DETouchWheelRadiusForBounds(200, 852), 88);
    near(DETouchWheelRadiusForBounds(0, 100), 0);
    near(DETouchWheelRadiusForBounds(-20, 100), 0);
    near(DETouchWheelRadiusForBounds(NAN, 100), 0);
    assert(DEWheelActionForOffset(0, -72, 88) == DECommandWheelNone);

    /* Every segment center, including angles wrapping across zero. */
    for (int i = 0; i < DECommandWheelActionCount; ++i) {
        assert(at_angle(i * pi / 3.0, 72, 108) == (DECommandWheelAction)i);
        assert(at_angle(i * pi / 3.0 - 2 * pi, 72, 108) == (DECommandWheelAction)i);
    }
    /* Both sides of every segment boundary choose their adjacent actions. */
    for (int i = 0; i < DECommandWheelActionCount; ++i) {
        double boundary = (i + 0.5) * pi / 3.0;
        assert(at_angle(boundary - 0.000001, 72, 108) == (DECommandWheelAction)i);
        assert(at_angle(boundary + 0.000001, 72, 108) ==
               (DECommandWheelAction)((i + 1) % DECommandWheelActionCount));
    }

    assert(DEWheelActionForOffset(0, 0, 108) == DECommandWheelNone);
    assert(DEWheelActionForOffset(0, -28, 108) == DECommandWheelNone); /* ratio is 28.08 */
    assert(DEWheelActionForOffset(0, -28.081, 108) == DECommandWheelOrder);
    assert(DEWheelActionForOffset(0, -28, 90) == DECommandWheelOrder);
    assert(DEWheelActionForOffset(0, -144, 108) == DECommandWheelOrder);
    assert(DEWheelActionForOffset(0, -144.001, 108) == DECommandWheelNone);
    assert(DEWheelActionForOffset(0, -72, 108) == DECommandWheelOrder); /* reentry */
    assert(DEWheelActionForOffset(0, 0, 108) == DECommandWheelNone);
    assert(DEWheelActionForOffset(0, -72, 108) == DECommandWheelOrder); /* center reentry */
    assert(DEWheelActionForOffset(NAN, 72, 108) == DECommandWheelNone);
    assert(DEWheelActionForOffset(72, INFINITY, 108) == DECommandWheelNone);
    assert(DEWheelActionForOffset(72, 0, -1) == DECommandWheelNone);

    double x, y;
    DEClampWheelCenter(0, 190, 0, 0, 852, 393, 108, &x, &y);
    near(x, 108); near(y, 190);
    DEClampWheelCenter(852, 190, 0, 0, 852, 393, 108, &x, &y);
    near(x, 744); near(y, 190);
    DEClampWheelCenter(426, 0, 0, 0, 852, 393, 108, &x, &y);
    near(x, 426); near(y, 108);
    DEClampWheelCenter(426, 393, 0, 0, 852, 393, 108, &x, &y);
    near(x, 426); near(y, 285);

    /* Asymmetric notch/home-indicator insets do not shift valid centers. */
    DEClampWheelCenter(0, 0, 59, 0, 818, 372, 108, &x, &y);
    near(x, 167); near(y, 108);
    DEClampWheelCenter(900, 400, 59, 0, 818, 372, 108, &x, &y);
    near(x, 710); near(y, 264);
    DEClampWheelCenter(500, 200, 59, 0, 818, 372, 108, &x, &y);
    near(x, 500); near(y, 200);

    /* Too-small, empty and malformed bounds never produce negative centers. */
    DEClampWheelCenter(0, 0, 10, 20, 110, 160, 108, &x, &y);
    near(x, 60); near(y, 90);
    DEClampWheelCenter(0, 0, 0, 0, 0, 0, 108, &x, &y);
    near(x, 0); near(y, 0);
    DEClampWheelCenter(NAN, INFINITY, -10, -20, -30, -40, 108, &x, &y);
    near(x, 0); near(y, 0);
    DEClampWheelCenter(200, 200, 0, 0, 500, 500, -1, &x, &y);
    near(x, 200); near(y, 200);
    DEClampWheelCenter(200, 200, 0, 0, 500, 500, 108, NULL, NULL);

    puts("PASS: compact layout, wheel sectors, cancellation/reentry, and safe-area clamping");
    return 0;
}
