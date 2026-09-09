// SPDX-License-Identifier: BSD-3-Clause
// Copyright Contributors to the OpenColorIO Project.
// Parameterless MSL equations extracted verbatim from OpenColorIO 2.5.2.
// Parameterized equations are translated from FixedFunctionOpGPU.cpp.
import Foundation

extension OCIONativeCompiler {
    mutating func fixedFunction(_ p: NativeParameters, inverse: Bool) throws -> String {
        let style = try p.string("style").lowercased()
        let params = try p.optionalVector("params", count: nil) ?? []
        if let source = Self.parameterlessFixedFunction(style: style, inverse: inverse) {
            guard params.isEmpty else { throw p.error("this fixed function does not accept parameters") }
            return source
        }
        return try parameterizedFixedFunction(style: style, params: params, inverse: inverse, owner: p)
    }

    private static func parameterlessFixedFunction(style: String, inverse: Bool) -> String? {
        switch style {
        case "aces_redmod03":
            if inverse {
                return """
                // Add FixedFunction 'ACES_RedMod03 (Inverse)' processing
                  
                  {
                    float a = 2.0 * pixel.rgb.r - (pixel.rgb.g + pixel.rgb.b);
                    float b = 1.7320508075688772 * (pixel.rgb.g - pixel.rgb.b);
                    float hue = atan2(b, a);
                    float knot_coord = clamp(2. + hue * float(1.9098593), 0., 4.);
                    int j = int(min(knot_coord, 3.));
                    float t = knot_coord - float(j);
                    float4 monomials = float4(t*t*t, t*t, t, 1.);
                    float4 m0 = float4(0.25, 0., 0., 0.);
                    float4 m1 = float4(-0.75, 0.75, 0.75, 0.25);
                    float4 m2 = float4(0.75, -1.5, 0., 1.);
                    float4 m3 = float4(-0.25, 0.75, -0.75, 0.25);
                    float4 coefs = mix(m0, m1, float(j == 1));
                    coefs = mix(coefs, m2, float(j == 2));
                    coefs = mix(coefs, m3, float(j == 3));
                    float f_H = dot(coefs, monomials);
                    if (f_H > 0.)
                    {
                      float maxval = max( pixel.rgb.r, max( pixel.rgb.g, pixel.rgb.b));
                      float minval = min( pixel.rgb.r, min( pixel.rgb.g, pixel.rgb.b));
                      float oldChroma = max(1e-10, maxval - minval);
                      float3 delta = pixel.rgb - minval;
                      float ka = f_H * 0.149999976 - 1.;
                      float kb = pixel.rgb.r - f_H * (0.0299999993 + minval) * 0.149999976;
                      float kc = f_H * 0.0299999993 * minval * 0.149999976;
                      pixel.rgb.r = ( -kb - sqrt( kb * kb - 4. * ka * kc)) / ( 2. * ka);
                      float maxval2 = max( pixel.rgb.r, max( pixel.rgb.g, pixel.rgb.b));
                      float newChroma = maxval2 - minval;
                      pixel.rgb = minval + delta * newChroma / oldChroma;
                    }
                  }
                """
            }
            return """
            // Add FixedFunction 'ACES_RedMod03 (Forward)' processing
              
              {
                float a = 2.0 * pixel.rgb.r - (pixel.rgb.g + pixel.rgb.b);
                float b = 1.7320508075688772 * (pixel.rgb.g - pixel.rgb.b);
                float hue = atan2(b, a);
                float knot_coord = clamp(2. + hue * float(1.9098593), 0., 4.);
                int j = int(min(knot_coord, 3.));
                float t = knot_coord - float(j);
                float4 monomials = float4(t*t*t, t*t, t, 1.);
                float4 m0 = float4(0.25, 0., 0., 0.);
                float4 m1 = float4(-0.75, 0.75, 0.75, 0.25);
                float4 m2 = float4(0.75, -1.5, 0., 1.);
                float4 m3 = float4(-0.25, 0.75, -0.75, 0.25);
                float4 coefs = mix(m0, m1, float(j == 1));
                coefs = mix(coefs, m2, float(j == 2));
                coefs = mix(coefs, m3, float(j == 3));
                float f_H = dot(coefs, monomials);
                float maxval = max( pixel.rgb.r, max( pixel.rgb.g, pixel.rgb.b));
                float minval = min( pixel.rgb.r, min( pixel.rgb.g, pixel.rgb.b));
                float oldChroma = max(1e-10, maxval - minval);
                float3 delta = pixel.rgb - minval;
                float f_S = ( max(1e-10, maxval) - max(1e-10, minval) ) / max(1e-2, maxval);
                pixel.rgb.r = pixel.rgb.r + f_H * f_S * (0.0299999993 - pixel.rgb.r) * 0.149999976;
                float maxval2 = max( pixel.rgb.r, max( pixel.rgb.g, pixel.rgb.b));
                float newChroma = maxval2 - minval;
                pixel.rgb = minval + delta * newChroma / oldChroma;
              }
            """
        case "aces_redmod10":
            if inverse {
                return """
                // Add FixedFunction 'ACES_RedMod10 (Inverse)' processing
                  
                  {
                    float a = 2.0 * pixel.rgb.r - (pixel.rgb.g + pixel.rgb.b);
                    float b = 1.7320508075688772 * (pixel.rgb.g - pixel.rgb.b);
                    float hue = atan2(b, a);
                    float knot_coord = clamp(2. + hue * float(1.6976527), 0., 4.);
                    int j = int(min(knot_coord, 3.));
                    float t = knot_coord - float(j);
                    float4 monomials = float4(t*t*t, t*t, t, 1.);
                    float4 m0 = float4(0.25, 0., 0., 0.);
                    float4 m1 = float4(-0.75, 0.75, 0.75, 0.25);
                    float4 m2 = float4(0.75, -1.5, 0., 1.);
                    float4 m3 = float4(-0.25, 0.75, -0.75, 0.25);
                    float4 coefs = mix(m0, m1, float(j == 1));
                    coefs = mix(coefs, m2, float(j == 2));
                    coefs = mix(coefs, m3, float(j == 3));
                    float f_H = dot(coefs, monomials);
                    if (f_H > 0.)
                    {
                      float minval = min( pixel.rgb.g, pixel.rgb.b);
                      float ka = f_H * 0.180000007 - 1.;
                      float kb = pixel.rgb.r - f_H * (0.0299999993 + minval) * 0.180000007;
                      float kc = f_H * 0.0299999993 * minval * 0.180000007;
                      pixel.rgb.r = ( -kb - sqrt( kb * kb - 4. * ka * kc)) / ( 2. * ka);
                    }
                  }
                """
            }
            return """
            // Add FixedFunction 'ACES_RedMod10 (Forward)' processing
              
              {
                float a = 2.0 * pixel.rgb.r - (pixel.rgb.g + pixel.rgb.b);
                float b = 1.7320508075688772 * (pixel.rgb.g - pixel.rgb.b);
                float hue = atan2(b, a);
                float knot_coord = clamp(2. + hue * float(1.6976527), 0., 4.);
                int j = int(min(knot_coord, 3.));
                float t = knot_coord - float(j);
                float4 monomials = float4(t*t*t, t*t, t, 1.);
                float4 m0 = float4(0.25, 0., 0., 0.);
                float4 m1 = float4(-0.75, 0.75, 0.75, 0.25);
                float4 m2 = float4(0.75, -1.5, 0., 1.);
                float4 m3 = float4(-0.25, 0.75, -0.75, 0.25);
                float4 coefs = mix(m0, m1, float(j == 1));
                coefs = mix(coefs, m2, float(j == 2));
                coefs = mix(coefs, m3, float(j == 3));
                float f_H = dot(coefs, monomials);
                float maxval = max( pixel.rgb.r, max( pixel.rgb.g, pixel.rgb.b));
                float minval = min( pixel.rgb.r, min( pixel.rgb.g, pixel.rgb.b));
                float f_S = ( max(1e-10, maxval) - max(1e-10, minval) ) / max(1e-2, maxval);
                pixel.rgb.r = pixel.rgb.r + f_H * f_S * (0.0299999993 - pixel.rgb.r) * 0.180000007;
              }
            """
        case "aces_glow03":
            if inverse {
                return """
                // Add FixedFunction 'ACES_Glow03 (Inverse)' processing
                  
                  {
                    float chroma = sqrt( pixel.rgb.b * (pixel.rgb.b - pixel.rgb.g) + pixel.rgb.g * (pixel.rgb.g - pixel.rgb.r) + pixel.rgb.r * (pixel.rgb.r - pixel.rgb.b) );
                    float YC = (pixel.rgb.b + pixel.rgb.g + pixel.rgb.r + 1.75 * chroma) / 3.;
                    float maxval = max( pixel.rgb.r, max( pixel.rgb.g, pixel.rgb.b));
                    float minval = min( pixel.rgb.r, min( pixel.rgb.g, pixel.rgb.b));
                    float sat = ( max(1e-10, maxval) - max(1e-10, minval) ) / max(1e-2, maxval);
                    float x = (sat - 0.4) * 5.;
                    float t = max( 0., 1. - 0.5 * abs(x));
                    float s = 0.5 * (1. + sign(x) * (1. - t * t));
                    float GlowGain = 0.075000003 * s;
                    float GlowMid = 0.100000001;
                    float glowGainOut = mix(-GlowGain / (1. + GlowGain), GlowGain * (GlowMid / YC - 0.5) / (GlowGain * 0.5 - 1.), float( YC > (1. + GlowGain) * GlowMid * 2. / 3. ));
                    glowGainOut = mix(glowGainOut, 0., float( YC > GlowMid * 2. ));
                    pixel.rgb = pixel.rgb * glowGainOut + pixel.rgb;
                  }
                """
            }
            return """
            // Add FixedFunction 'ACES_Glow03 (Forward)' processing
              
              {
                float chroma = sqrt( pixel.rgb.b * (pixel.rgb.b - pixel.rgb.g) + pixel.rgb.g * (pixel.rgb.g - pixel.rgb.r) + pixel.rgb.r * (pixel.rgb.r - pixel.rgb.b) );
                float YC = (pixel.rgb.b + pixel.rgb.g + pixel.rgb.r + 1.75 * chroma) / 3.;
                float maxval = max( pixel.rgb.r, max( pixel.rgb.g, pixel.rgb.b));
                float minval = min( pixel.rgb.r, min( pixel.rgb.g, pixel.rgb.b));
                float sat = ( max(1e-10, maxval) - max(1e-10, minval) ) / max(1e-2, maxval);
                float x = (sat - 0.4) * 5.;
                float t = max( 0., 1. - 0.5 * abs(x));
                float s = 0.5 * (1. + sign(x) * (1. - t * t));
                float GlowGain = 0.075000003 * s;
                float GlowMid = 0.100000001;
                float glowGainOut = mix(GlowGain, GlowGain * (GlowMid / YC - 0.5), float( YC > GlowMid * 2. / 3. ));
                glowGainOut = mix(glowGainOut, 0., float( YC > GlowMid * 2. ));
                pixel.rgb = pixel.rgb * glowGainOut + pixel.rgb;
              }
            """
        case "aces_glow10":
            if inverse {
                return """
                // Add FixedFunction 'ACES_Glow10 (Inverse)' processing
                  
                  {
                    float chroma = sqrt( pixel.rgb.b * (pixel.rgb.b - pixel.rgb.g) + pixel.rgb.g * (pixel.rgb.g - pixel.rgb.r) + pixel.rgb.r * (pixel.rgb.r - pixel.rgb.b) );
                    float YC = (pixel.rgb.b + pixel.rgb.g + pixel.rgb.r + 1.75 * chroma) / 3.;
                    float maxval = max( pixel.rgb.r, max( pixel.rgb.g, pixel.rgb.b));
                    float minval = min( pixel.rgb.r, min( pixel.rgb.g, pixel.rgb.b));
                    float sat = ( max(1e-10, maxval) - max(1e-10, minval) ) / max(1e-2, maxval);
                    float x = (sat - 0.4) * 5.;
                    float t = max( 0., 1. - 0.5 * abs(x));
                    float s = 0.5 * (1. + sign(x) * (1. - t * t));
                    float GlowGain = 0.0500000007 * s;
                    float GlowMid = 0.0799999982;
                    float glowGainOut = mix(-GlowGain / (1. + GlowGain), GlowGain * (GlowMid / YC - 0.5) / (GlowGain * 0.5 - 1.), float( YC > (1. + GlowGain) * GlowMid * 2. / 3. ));
                    glowGainOut = mix(glowGainOut, 0., float( YC > GlowMid * 2. ));
                    pixel.rgb = pixel.rgb * glowGainOut + pixel.rgb;
                  }
                """
            }
            return """
            // Add FixedFunction 'ACES_Glow10 (Forward)' processing
              
              {
                float chroma = sqrt( pixel.rgb.b * (pixel.rgb.b - pixel.rgb.g) + pixel.rgb.g * (pixel.rgb.g - pixel.rgb.r) + pixel.rgb.r * (pixel.rgb.r - pixel.rgb.b) );
                float YC = (pixel.rgb.b + pixel.rgb.g + pixel.rgb.r + 1.75 * chroma) / 3.;
                float maxval = max( pixel.rgb.r, max( pixel.rgb.g, pixel.rgb.b));
                float minval = min( pixel.rgb.r, min( pixel.rgb.g, pixel.rgb.b));
                float sat = ( max(1e-10, maxval) - max(1e-10, minval) ) / max(1e-2, maxval);
                float x = (sat - 0.4) * 5.;
                float t = max( 0., 1. - 0.5 * abs(x));
                float s = 0.5 * (1. + sign(x) * (1. - t * t));
                float GlowGain = 0.0500000007 * s;
                float GlowMid = 0.0799999982;
                float glowGainOut = mix(GlowGain, GlowGain * (GlowMid / YC - 0.5), float( YC > GlowMid * 2. / 3. ));
                glowGainOut = mix(glowGainOut, 0., float( YC > GlowMid * 2. ));
                pixel.rgb = pixel.rgb * glowGainOut + pixel.rgb;
              }
            """
        case "aces_darktodim10":
            if inverse {
                return """
                // Add FixedFunction 'ACES_DarkToDim10 (Inverse)' processing
                  
                  {
                    float Y = max( 1e-10, 0.27222871678091454 * pixel.rgb.r + 0.67408176581114831 * pixel.rgb.g + 0.053689517407937051 * pixel.rgb.b );
                    float Ypow_over_Y = pow( Y, 0.019264102);
                    pixel.rgb = pixel.rgb * Ypow_over_Y;
                  }
                """
            }
            return """
            // Add FixedFunction 'ACES_DarkToDim10 (Forward)' processing
              
              {
                float Y = max( 1e-10, 0.27222871678091454 * pixel.rgb.r + 0.67408176581114831 * pixel.rgb.g + 0.053689517407937051 * pixel.rgb.b );
                float Ypow_over_Y = pow( Y, -0.0188999772);
                pixel.rgb = pixel.rgb * Ypow_over_Y;
              }
            """
        case "rgb_to_hsv":
            if inverse {
                return """
                // Add FixedFunction 'HSV_TO_RGB' processing
                  
                  {
                    float Hue = ( pixel.rgb.r - floor( pixel.rgb.r ) ) * 6.0;
                    float Sat = clamp( pixel.rgb.g, 0., 1.999 );
                    float Val = pixel.rgb.b;
                    float R = abs(Hue - 3.0) - 1.0;
                    float G = 2.0 - abs(Hue - 2.0);
                    float B = 2.0 - abs(Hue - 4.0);
                    float3 RGB = float3(R, G, B);
                    RGB = clamp( RGB, 0., 1. );
                    float rgbMax = Val;
                    float rgbMin = Val * (1.0 - Sat);
                    if ( Sat > 1.0 )
                    {
                      rgbMin = Val * (1.0 - Sat) / (2.0 - Sat);
                      rgbMax = Val - rgbMin;
                    }
                    if ( Val < 0.0 )
                    {
                      rgbMin = Val / (2.0 - Sat);
                      rgbMax = Val - rgbMin;
                    }
                    RGB = RGB * (rgbMax - rgbMin) + rgbMin;
                    pixel.rgb = RGB;
                  }
                """
            }
            return """
            // Add FixedFunction 'RGB_TO_HSV' processing
              
              {
                float minRGB = min( pixel.rgb.r, min( pixel.rgb.g, pixel.rgb.b ) );
                float maxRGB = max( pixel.rgb.r, max( pixel.rgb.g, pixel.rgb.b ) );
                float val = maxRGB;
                float sat = 0.0, hue = 0.0;
                if (minRGB != maxRGB)
                {
                  if (val != 0.0) sat = (maxRGB - minRGB) / val;
                  float OneOverMaxMinusMin = 1.0 / (maxRGB - minRGB);
                  if ( maxRGB == pixel.rgb.r ) hue = (pixel.rgb.g - pixel.rgb.b) * OneOverMaxMinusMin;
                  else if ( maxRGB == pixel.rgb.g ) hue = 2.0 + (pixel.rgb.b - pixel.rgb.r) * OneOverMaxMinusMin;
                  else hue = 4.0 + (pixel.rgb.r - pixel.rgb.g) * OneOverMaxMinusMin;
                  if ( hue < 0.0 ) hue += 6.0;
                }
                if ( minRGB < 0.0 ) val += minRGB;
                if ( -minRGB > maxRGB ) sat = (maxRGB - minRGB) / -minRGB;
                pixel.rgb = float3(hue * 1./6., sat, val);
              }
            """
        case "xyz_to_xyy":
            if inverse {
                return """
                // Add FixedFunction 'xyY_TO_XYZ' processing
                  
                  {
                    float d = (pixel.rgb.g == 0.) ? 0. : 1. / pixel.rgb.g;
                    float Y = pixel.rgb.b;
                    pixel.rgb.b = Y * (1. - pixel.rgb.r - pixel.rgb.g) * d;
                    pixel.rgb.r *= Y * d;
                    pixel.rgb.g = Y;
                  }
                """
            }
            return """
            // Add FixedFunction 'XYZ_TO_xyY' processing
              
              {
                float d = pixel.rgb.r + pixel.rgb.g + pixel.rgb.b;
                d = (d == 0.) ? 0. : 1. / d;
                pixel.rgb.b = pixel.rgb.g;
                pixel.rgb.r *= d;
                pixel.rgb.g *= d;
              }
            """
        case "xyz_to_uvy":
            if inverse {
                return """
                // Add FixedFunction 'uvY_TO_XYZ' processing
                  
                  {
                    float d = (pixel.rgb.g == 0.) ? 0. : 1. / pixel.rgb.g;
                    float Y = pixel.rgb.b;
                    pixel.rgb.b = (3./4.) * Y * (4. - pixel.rgb.r - 6.6666666666666667 * pixel.rgb.g) * d;
                    pixel.rgb.r *= (9./4.) * Y * d;
                    pixel.rgb.g = Y;
                  }
                """
            }
            return """
            // Add FixedFunction 'XYZ_TO_uvY' processing
              
              {
                float d = pixel.rgb.r + 15. * pixel.rgb.g + 3. * pixel.rgb.b;
                d = (d == 0.) ? 0. : 1. / d;
                pixel.rgb.b = pixel.rgb.g;
                pixel.rgb.r *= 4. * d;
                pixel.rgb.g *= 9. * d;
              }
            """
        case "xyz_to_luv":
            if inverse {
                return """
                // Add FixedFunction 'LUV_TO_XYZ' processing
                  
                  {
                    float Lstar = pixel.rgb.r;
                    float d = (Lstar == 0.) ? 0. : 0.076923076923076927 / Lstar;
                    float u = pixel.rgb.g * d + 0.19783001;
                    float v = pixel.rgb.b * d + 0.46831999;
                    float tmp = (Lstar + 0.16) * 0.86206896551724144;
                    float Y = mix(tmp * tmp * tmp, 0.11070564598794539 * Lstar, float(Lstar <= 0.08));
                    float dd = (v == 0.) ? 0. : 0.25 / v;
                    pixel.rgb.r = 9. * Y * u * dd;
                    pixel.rgb.b = Y * (12. - 3. * u - 20. * v) * dd;
                    pixel.rgb.g = Y;
                  }
                """
            }
            return """
            // Add FixedFunction 'XYZ_TO_LUV' processing
              
              {
                float d = pixel.rgb.r + 15. * pixel.rgb.g + 3. * pixel.rgb.b;
                d = (d == 0.) ? 0. : 1. / d;
                float u = pixel.rgb.r * 4. * d;
                float v = pixel.rgb.g * 9. * d;
                float Y = pixel.rgb.g;
                float Lstar = mix(1.16 * pow( max(0., Y), 1./3. ) - 0.16, 9.0329629629629608 * Y, float(Y <= 0.008856451679));
                float ustar = 13. * Lstar * (u - 0.19783001);
                float vstar = 13. * Lstar * (v - 0.46831999);
                pixel.rgb = float3(Lstar, ustar, vstar);
              }
            """
        case "lin_to_pq":
            if inverse {
                return """
                // Add FixedFunction 'PQ_TO_Lin' processing
                  
                  {
                    float3 sign3 = sign(pixel.rgb);
                    float3 x = pow(abs(pixel.rgb), float3(0.012683313515655966, 0.012683313515655966, 0.012683313515655966));
                    pixel.rgb = 100. * sign3 * pow(max(float3(0., 0., 0.), x - float3(0.8359375, 0.8359375, 0.8359375)) / (float3(18.8515625, 18.8515625, 18.8515625) - 18.6875 * x), float3(6.2773946360153259, 6.2773946360153259, 6.2773946360153259));
                  }
                """
            }
            return """
            // Add FixedFunction 'Lin_TO_PQ' processing
              
              {
                float3 sign3 = sign(pixel.rgb);
                float3 L = abs(0.01 * pixel.rgb);
                float3 y = pow(L, float3(0.1593017578125, 0.1593017578125, 0.1593017578125));
                float3 ratpoly = (float3(0.8359375, 0.8359375, 0.8359375) + 18.8515625 * y) / (float3(1., 1., 1.) + 18.6875 * y);
                pixel.rgb = sign3 * pow(ratpoly, float3(78.84375, 78.84375, 78.84375));
              }
            """
        case "rgb_to_hsy_lin":
            if inverse {
                return """
                // Add FixedFunction 'HSY_LIN_TO_RGB' processing
                  
                  {
                    float luma = pixel.z;
                    float Hue = pixel.x - 1./6.;
                    Hue = (luma < 0.) ? Hue + 0.5 : Hue;
                    Hue = ( Hue - floor( Hue ) ) * 6.0;
                    float R = abs(Hue - 3.0) - 1.0;
                    float G = 2.0 - abs(Hue - 2.0);
                    float B = 2.0 - abs(Hue - 4.0);
                    float3 RGB0 = float3(R, G, B);
                    RGB0 = clamp( RGB0, 0., 1. );
                    float3 lumaWeights = float3(0.212599993, 0.715200007, 0.0722000003);
                    float3 ones = float3(1., 1., 1.);
                    float currY = dot(RGB0, lumaWeights);
                    RGB0 *= luma / currY;
                    float sat = pixel.y;
                    float distRGB = dot( abs(RGB0 - luma), ones );
                    float sumRGB  = dot( RGB0, ones );
                    float k = 0.15;
                    float lo_gain = 5.;
                    sat /= 1.4;
                    float tmp = -sat * sumRGB + sat * 3. * luma + distRGB;
                    tmp = max(1e-6, tmp);
                    float s1 = sat * (k + 3. * luma) / tmp;
                    s1 = min(s1, 50.);
                    float s0 = sat / max(1e-10, distRGB * lo_gain);
                    float alpha  = clamp( (luma - 0.001) / (0.01 - 0.001), 0., 1.);
                    float a = distRGB * lo_gain * (1. - alpha) * (sumRGB - 3. * luma);
                    float b = distRGB * lo_gain * (1. - alpha) * (k + 3. * luma) + distRGB * alpha - sat * (sumRGB - 3. * luma);
                    float c = -sat * (k + 3. * luma);
                    float discrim = sqrt( b * b - 4. * a * c );
                    float denom = -discrim - b;
                    float sm = (2. * c) / denom;
                    sm = (sm >= 0.) ? sm : (2. * c) / (denom + discrim * 2.);
                    float gainS = (alpha == 1.) ? s1 : (alpha == 0.) ? s0 : sm;
                    pixel.rgb = luma + gainS * (RGB0 - luma);
                  }
                """
            }
            return """
            // Add FixedFunction 'RGB_TO_HSY_LIN' processing
              
              {
                float3 lumaWeights = float3(0.212599993, 0.715200007, 0.0722000003);
                float3 ones = float3(1., 1., 1.);
                float luma = dot(pixel.rgb, lumaWeights);
                float minRGB =  min( pixel.x, min( pixel.y, pixel.z ) );
                float maxRGB =  max( pixel.x, max( pixel.y, pixel.z ) );
                float3 RGBm = pixel.rgb - luma;
                float distRGB  = dot( abs(RGBm), ones );
                float sumRGB  = dot( pixel.rgb, ones );
                float sat_hi  = distRGB / max(0.07 * distRGB + 1e-6, 0.15 + sumRGB);
                float sat_lo  = distRGB * 5.;
                float alpha  = clamp( (luma - 0.001) / (0.01 - 0.001), 0., 1.);
                float sat = sat_lo + alpha * (sat_hi - sat_lo);
                sat *= 1.4;
                float hue = 0.0;
                if (minRGB != maxRGB) {
                   float OneOverMaxMinusMin = 1.0 / (maxRGB - minRGB);
                   if ( maxRGB == pixel.r ) hue = 1.0 + (pixel.g - pixel.b) * OneOverMaxMinusMin;
                   else if ( maxRGB == pixel.g ) hue = 3.0 + (pixel.b - pixel.r) * OneOverMaxMinusMin;
                   else hue = 5.0 + (pixel.r - pixel.g) * OneOverMaxMinusMin;
                }
                pixel.r = hue * 1./6.; pixel.g = sat; pixel.b = luma;
              }
            """
        case "rgb_to_hsy_log":
            if inverse {
                return """
                // Add FixedFunction 'HSY_LOG_TO_RGB' processing
                  
                  {
                    float luma = pixel.z;
                    float Hue = pixel.x - 1./6.;
                    Hue = (luma < 0.) ? Hue + 0.5 : Hue;
                    Hue = ( Hue - floor( Hue ) ) * 6.0;
                    float R = abs(Hue - 3.0) - 1.0;
                    float G = 2.0 - abs(Hue - 2.0);
                    float B = 2.0 - abs(Hue - 4.0);
                    float3 RGB0 = float3(R, G, B);
                    RGB0 = clamp( RGB0, 0., 1. );
                    float3 lumaWeights = float3(0.212599993, 0.715200007, 0.0722000003);
                    float3 ones = float3(1., 1., 1.);
                    float currY = dot(RGB0, lumaWeights);
                    RGB0 *= luma / currY;
                    float sat = pixel.y;
                    float distRGB = dot( abs(RGB0 - luma), ones );
                    float gainS = sat / max(1e-10, distRGB * 4.);
                    pixel.rgb = luma + gainS * (RGB0 - luma);
                  }
                """
            }
            return """
            // Add FixedFunction 'RGB_TO_HSY_LOG' processing
              
              {
                float3 lumaWeights = float3(0.212599993, 0.715200007, 0.0722000003);
                float3 ones = float3(1., 1., 1.);
                float luma = dot(pixel.rgb, lumaWeights);
                float minRGB =  min( pixel.x, min( pixel.y, pixel.z ) );
                float maxRGB =  max( pixel.x, max( pixel.y, pixel.z ) );
                float3 RGBm = pixel.rgb - luma;
                float distRGB  = dot( abs(RGBm), ones );
                float sat = distRGB * 4.;
                float hue = 0.0;
                if (minRGB != maxRGB) {
                   float OneOverMaxMinusMin = 1.0 / (maxRGB - minRGB);
                   if ( maxRGB == pixel.r ) hue = 1.0 + (pixel.g - pixel.b) * OneOverMaxMinusMin;
                   else if ( maxRGB == pixel.g ) hue = 3.0 + (pixel.b - pixel.r) * OneOverMaxMinusMin;
                   else hue = 5.0 + (pixel.r - pixel.g) * OneOverMaxMinusMin;
                }
                pixel.r = hue * 1./6.; pixel.g = sat; pixel.b = luma;
              }
            """
        case "rgb_to_hsy_vid":
            if inverse {
                return """
                // Add FixedFunction 'HSY_VID_TO_RGB' processing
                  
                  {
                    float luma = pixel.z;
                    float Hue = pixel.x - 1./6.;
                    Hue = (luma < 0.) ? Hue + 0.5 : Hue;
                    Hue = ( Hue - floor( Hue ) ) * 6.0;
                    float R = abs(Hue - 3.0) - 1.0;
                    float G = 2.0 - abs(Hue - 2.0);
                    float B = 2.0 - abs(Hue - 4.0);
                    float3 RGB0 = float3(R, G, B);
                    RGB0 = clamp( RGB0, 0., 1. );
                    float3 lumaWeights = float3(0.212599993, 0.715200007, 0.0722000003);
                    float3 ones = float3(1., 1., 1.);
                    float currY = dot(RGB0, lumaWeights);
                    RGB0 *= luma / currY;
                    float sat = pixel.y;
                    float distRGB = dot( abs(RGB0 - luma), ones );
                    float gainS = sat / max(1e-10, distRGB * 1.25);
                    pixel.rgb = luma + gainS * (RGB0 - luma);
                  }
                """
            }
            return """
            // Add FixedFunction 'RGB_TO_HSY_VID' processing
              
              {
                float3 lumaWeights = float3(0.212599993, 0.715200007, 0.0722000003);
                float3 ones = float3(1., 1., 1.);
                float luma = dot(pixel.rgb, lumaWeights);
                float minRGB =  min( pixel.x, min( pixel.y, pixel.z ) );
                float maxRGB =  max( pixel.x, max( pixel.y, pixel.z ) );
                float3 RGBm = pixel.rgb - luma;
                float distRGB  = dot( abs(RGBm), ones );
                float sat = distRGB * 1.25;
                float hue = 0.0;
                if (minRGB != maxRGB) {
                   float OneOverMaxMinusMin = 1.0 / (maxRGB - minRGB);
                   if ( maxRGB == pixel.r ) hue = 1.0 + (pixel.g - pixel.b) * OneOverMaxMinusMin;
                   else if ( maxRGB == pixel.g ) hue = 3.0 + (pixel.b - pixel.r) * OneOverMaxMinusMin;
                   else hue = 5.0 + (pixel.r - pixel.g) * OneOverMaxMinusMin;
                }
                pixel.r = hue * 1./6.; pixel.g = sat; pixel.b = luma;
              }
            """
        default: return nil
        }
    }
}

extension OCIONativeCompiler {
    mutating func parameterizedFixedFunction(style: String, params: [Double], inverse: Bool,
                                             owner: NativeParameters) throws -> String {
        func count(_ required: Int) throws {
            guard params.count == required else { throw owner.error("\(style) requires exactly \(required) parameters") }
        }
        switch style {
        case "rec2100_surround":
            try count(1)
            guard (0.01...100).contains(params[0]) else { throw owner.error("surround gamma must lie in [0.01, 100]") }
            let gamma = Float(params[0])
            let floor = inverse ? pow(Float(0.0001), gamma) : Float(0.0001)
            let power = (inverse ? 1 / gamma : gamma) - 1
            return "{ float Y = max(\(ffNumber(Double(floor))), abs(dot(pixel.rgb, float3(0.2627f, 0.6780f, 0.0593f)))); pixel.rgb *= pow(Y, \(ffNumber(Double(power)))); }"
        case "aces_gamutcomp13":
            try count(7)
            guard params[0..<3].allSatisfy({ (1.001...65504).contains($0) }),
                  params[3..<6].allSatisfy({ (0...0.9995).contains($0) }),
                  (1...65504).contains(params[6]) else { throw owner.error("ACES 1.3 gamut compression parameters lie outside upstream bounds") }
            let values = params.map(Float.init)
            let power = values[6]
            var body = "{ float ach = max(pixel.r, max(pixel.g, pixel.b)); if (ach != 0.0f) { float3 dist = (ach - pixel.rgb) / abs(ach); float3 cdist = dist;\n"
            for channel in 0..<3 {
                let threshold = values[channel + 3]
                let delta = values[channel] - threshold
                let scale = delta / pow(pow((1 - threshold) / delta, -power) - 1, 1 / power)
                let t = ffNumber(Double(threshold)), s = ffNumber(Double(scale)), p = ffNumber(Double(power))
                let inversePower = ffNumber(Double(1 / power))
                if inverse {
                    body += "if (dist[\(channel)] >= \(t) && dist[\(channel)] < \(ffNumber(Double(threshold + scale)))) { float nd = (dist[\(channel)] - \(t)) / \(s); float p = pow(nd, \(p)); cdist[\(channel)] = \(t) + \(s) * pow(-(p / (p - 1.0f)), \(inversePower)); }\n"
                } else {
                    body += "if (dist[\(channel)] >= \(t)) { float nd = (dist[\(channel)] - \(t)) / \(s); float p = pow(nd, \(p)); cdist[\(channel)] = \(t) + \(s) * nd / pow(1.0f + p, \(inversePower)); }\n"
                }
            }
            return body + "pixel.rgb = ach - cdist * abs(ach); } }"
        case "lin_to_gammalog":
            try count(10)
            guard params[5] > 0, params[0] < params[1], params[2] != 0 else {
                throw owner.error("gamma-log requires positive base, mirror < break and nonzero gamma")
            }
            return fixedGammaLog(params, inverse: inverse)
        case "lin_to_doublelog":
            try count(13)
            guard params[0] > 0, params[1] <= params[2] else { throw owner.error("double-log requires positive base and ordered breakpoints") }
            return fixedDoubleLog(params, inverse: inverse)
        case "aces2_rgb_to_jmh":
            try count(8)
            return try fixedACES2RGBToJMh(params, inverse: inverse, owner: owner)
        case "aces2_tonescalecompress":
            try count(1)
            guard (1...10000).contains(params[0]), params[0].rounded(.down) == params[0] else {
                throw owner.error("ACES 2 peak luminance must be an integer in [1, 10000]")
            }
            return try fixedACES2ToneScale(peak: Float(params[0]), inverse: inverse)
        case "aces2_outputtransform", "aces2_gamutcompress":
            try count(9)
            guard (1...10000).contains(params[0]), params[0].rounded(.down) == params[0] else {
                throw owner.error("ACES 2 peak luminance must be an integer in [1, 10000]")
            }
            if style == "aces2_gamutcompress" {
                return try fixedACES2Gamut(peak: Float(params[0]), primaries: Array(params[1...]), inverse: inverse)
            }
            let ap0 = [0.7347, 0.2653, 0, 1, 0.0001, -0.077, 0.32168, 0.33767]
            let primaries = Array(params[1...])
            if inverse {
                let toJMh = try fixedACES2RGBToJMh(primaries, inverse: false, owner: owner)
                let gamut = try fixedACES2Gamut(peak: Float(params[0]), primaries: primaries, inverse: true)
                let tone = try fixedACES2ToneScale(peak: Float(params[0]), inverse: true)
                let toRGB = try fixedACES2RGBToJMh(ap0, inverse: true, owner: owner, roundPrimaries: false)
                return [toJMh, gamut, tone, toRGB].joined(separator: "\n")
            }
            let toJMh = try fixedACES2RGBToJMh(ap0, inverse: false, owner: owner, roundPrimaries: false)
            let tone = try fixedACES2ToneScale(peak: Float(params[0]), inverse: false)
            let gamut = try fixedACES2Gamut(peak: Float(params[0]), primaries: primaries, inverse: false)
            let toRGB = try fixedACES2RGBToJMh(primaries, inverse: true, owner: owner)
            return [toJMh, tone, gamut, toRGB].joined(separator: "\n")
        default:
            throw OCIOConfigError.unavailableTransform("FixedFunctionTransform style '\(style)' is unknown or unimplemented by upstream")
        }
    }

    private func fixedGammaLog(_ p: [Double], inverse: Bool) -> String {
        let slope = p[6] / log(p[5])
        let mirror = inverse ? p[3] * pow(p[0] + p[4], p[2]) : p[0]
        let breakpoint = inverse ? p[3] * pow(p[1] + p[4], p[2]) : p[1]
        var body = "{ float3 mirrorin = pixel.rgb - \(ffNumber(mirror)); float3 sign3 = sign(mirrorin); float3 E = abs(mirrorin) + \(ffNumber(mirror)); float3 above = select(float3(0.0f), float3(1.0f), E > \(ffNumber(breakpoint)));\n"
        if inverse {
            body += "float3 gamma = pow(E * \(ffNumber(1 / p[3])), float3(\(ffNumber(1 / p[2])))) - \(ffNumber(p[4]));\n"
            body += "float3 logarithmic = (exp((E - \(ffNumber(p[7]))) * \(ffNumber(1 / slope))) - \(ffNumber(p[9]))) * \(ffNumber(1 / p[8]));\n"
        } else {
            body += "float3 gamma = \(ffNumber(p[3])) * pow(E - \(ffNumber(p[4])), float3(\(ffNumber(p[2]))));\n"
            body += "float3 logarithmic = \(ffNumber(slope)) * log(max(1.0f - above, E * \(ffNumber(p[8])) + \(ffNumber(p[9])))) + \(ffNumber(p[7]));\n"
        }
        return body + "pixel.rgb = sign3 * (above * logarithmic + (1.0f - above) * gamma); }"
    }

    private func fixedDoubleLog(_ p: [Double], inverse: Bool) -> String {
        let slope1 = p[3] / log(p[0]), slope2 = p[7] / log(p[0])
        let break1 = inverse ? slope1 * log(p[5] * p[1] + p[6]) + p[4] : p[1]
        let break2 = inverse ? slope2 * log(p[9] * p[2] + p[10]) + p[8] : p[2]
        var body = "{ float3 seg1 = select(float3(0.0f), float3(1.0f), pixel.rgb <= \(ffNumber(break1))); float3 seg3 = select(float3(0.0f), float3(1.0f), pixel.rgb >= \(ffNumber(break2))); float3 seg2 = 1.0f - seg1 - seg3;\n"
        if inverse {
            body += "float3 log1 = (exp((pixel.rgb - \(ffNumber(p[4]))) * \(ffNumber(1 / slope1))) - \(ffNumber(p[6]))) * \(ffNumber(1 / p[5]));\n"
            body += "float3 log2 = (exp((pixel.rgb - \(ffNumber(p[8]))) * \(ffNumber(1 / slope2))) - \(ffNumber(p[10]))) * \(ffNumber(1 / p[9]));\n"
            body += "float3 lin = (pixel.rgb - \(ffNumber(p[12]))) * \(ffNumber(1 / p[11]));\n"
        } else {
            body += "float3 log1 = \(ffNumber(slope1)) * log(max(1.0f - seg1, pixel.rgb * \(ffNumber(p[5])) + \(ffNumber(p[6])))) + \(ffNumber(p[4]));\n"
            body += "float3 log2 = \(ffNumber(slope2)) * log(max(1.0f - seg3, pixel.rgb * \(ffNumber(p[9])) + \(ffNumber(p[10])))) + \(ffNumber(p[8]));\n"
            body += "float3 lin = \(ffNumber(p[11])) * pixel.rgb + \(ffNumber(p[12]));\n"
        }
        return body + "pixel.rgb = seg1 * log1 + seg2 * lin + seg3 * log2; }"
    }
}

private func ffNumber(_ value: Double) -> String {
    let converted = Float(value)
    if converted.isNaN { return "as_type<float>(0x7fc00000u)" }
    if converted == .infinity { return "as_type<float>(0x7f800000u)" }
    if converted == -.infinity { return "as_type<float>(0xff800000u)" }
    return mslNumber(value)
}

extension OCIONativeCompiler {
    private func fixedACES2RGBToJMh(_ parameters: [Double], inverse: Bool,
                                    owner: NativeParameters, roundPrimaries: Bool = true) throws -> String {
        let p = try FFJMhParameters(primaries: roundPrimaries ? parameters.map { Double(Float($0)) } : parameters)
        if inverse {
            return """
            {
                float hue = pixel.b - floor(pixel.b / 360.0f) * 360.0f;
                hue = (hue < 0.0f) ? hue + 360.0f : hue;
                float angle = hue * \(ffNumber(Double(Float.pi / 180)));
                float3 Aab = float3(pow(pixel.r * 0.01f, \(ffNumber(Double(p.inverseCZ)))), pixel.g * cos(angle), pixel.g * sin(angle));
                float3 response = \(ffMatrixProduct(p.aabToCone, "Aab"));
                float3 limited = min(abs(response), float3(0.99f));
                float3 lms = sign(response) * pow(27.13f * limited / (1.0f - limited), float3(\(ffNumber(Double(Float(1) / Float(0.42))))));
                pixel.rgb = \(ffMatrixProduct(p.camToRGB, "lms"));
            }
            """
        }
        return """
        {
            float3 lms = \(ffMatrixProduct(p.rgbToCAM, "pixel.rgb"));
            float3 compressed = pow(abs(lms), float3(0.42f));
            float3 response = sign(lms) * compressed / (27.13f + compressed);
            float3 Aab = \(ffMatrixProduct(p.coneToAab, "response"));
            if (Aab.r <= 0.0f) { pixel.rgb = float3(0.0f); }
            else {
                float J = 100.0f * pow(Aab.r, \(ffNumber(Double(p.cz))));
                float M = (J == 0.0f) ? 0.0f : sqrt(Aab.g * Aab.g + Aab.b * Aab.b);
                float h = (Aab.g == 0.0f) ? 0.0f : atan2(Aab.b, Aab.g) * \(ffNumber(180 / 3.14159265358979));
                h -= floor(h / 360.0f) * 360.0f;
                h = (h < 0.0f) ? h + 360.0f : h;
                pixel.rgb = float3(J, M, h);
            }
        }
        """
    }
}

/// Native Float32 preparation from ACES2::init_JMhParams, with Double matrix inversion as in upstream.
private struct FFJMhParameters {
    let rgbToCAM: [Float]
    let camToRGB: [Float]
    let coneToAab: [Float]
    let aabToCone: [Float]
    let cz: Float
    let inverseCZ: Float
    let luminanceScale: Float
    let whiteResponse: Float

    init(primaries: [Double]) throws {
        let camPrimaries = [0.8336, 0.1735, 2.3854, -1.4659, 0.087, -0.125, 0.333, 0.333]
        let camDouble = try ffRGBToXYZ(camPrimaries)
        let matrix16 = try ffInverse33(camDouble).map(Float.init)
        let rgbToXYZ = try ffRGBToXYZ(primaries).map(Float.init)
        let whiteXYZ = ffMatrixVector(rgbToXYZ, [100, 100, 100])
        let whiteRGB = ffMatrixVector(matrix16, whiteXYZ)
        let k: Float = 1 / 501
        let k4 = k * k * k * k
        let fl: Float = 0.2 * k4 * 500 + 0.1 * pow(1 - k4, 2) * pow(500, Float(1) / 3)
        let fln = fl / 100
        luminanceScale = fln
        let gamma: Float = 0.59 * (1.48 + sqrt(Float(20) / 100))
        cz = gamma
        inverseCZ = 1 / gamma
        let adaptation = whiteRGB.map { fln * whiteXYZ[1] / $0 }
        let adaptedWhite = zip(adaptation, whiteRGB).map(*)
        let response = adaptedWhite.map { value -> Float in
            let powered = pow(abs(value), Float(0.42))
            return (value < 0 ? -powered : powered) / (27.13 + powered)
        }
        let base: [Float] = [2, 1, 1 / 20, 1, -12 / 11, 1 / 11, 1 / 9, 1 / 9, -2 / 9]
        let cone = base.map { $0 * 400 }
        let aw = cone[0] * response[0] + cone[1] * response[1] + cone[2] * response[2]
        let flPower = pow(fl, Float(0.42))
        whiteResponse = flPower / (27.13 + flPower)
        var cam = ffMatrixMultiply(matrix16, rgbToXYZ)
        cam = cam.map { $0 * 100 }
        for row in 0..<3 { for col in 0..<3 { cam[row * 3 + col] *= adaptation[row] } }
        rgbToCAM = cam
        camToRGB = try ffInverse33(cam.map(Double.init)).map(Float.init)
        var aab = cone
        for index in 0..<3 { aab[index] /= aw }
        for index in 3..<9 { aab[index] = aab[index] * 43 * 0.9 }
        coneToAab = aab
        aabToCone = try ffInverse33(aab.map(Double.init)).map(Float.init)
        guard (rgbToCAM + camToRGB + coneToAab + aabToCone).allSatisfy(\.isFinite) else {
            throw OCIOConfigError.invalid("ACES 2 primaries generate a nonfinite appearance matrix")
        }
    }
}

private func ffRGBToXYZ(_ p: [Double]) throws -> [Double] {
    guard p.count == 8, p[7] != 0 else { throw OCIOConfigError.invalid("primaries require 8 coordinates and nonzero white y") }
    let matrix = [p[0], p[2], p[4], p[1], p[3], p[5], 1 - p[0] - p[1], 1 - p[2] - p[3], 1 - p[4] - p[5]]
    let inverse = try ffInverse33(matrix)
    let white = [p[6] / p[7], 1, (1 - p[6] - p[7]) / p[7]]
    let gains = (0..<3).map { row in inverse[row * 3] * white[0] + inverse[row * 3 + 1] * white[1] + inverse[row * 3 + 2] * white[2] }
    return (0..<9).map { matrix[$0] * gains[$0 % 3] }
}

private func ffInverse33(_ matrix: [Double]) throws -> [Double] {
    let expanded = [matrix[0], matrix[1], matrix[2], 0, matrix[3], matrix[4], matrix[5], 0,
                    matrix[6], matrix[7], matrix[8], 0, 0, 0, 0, 1]
    let inverse = try invertMatrix(expanded)
    return [inverse[0], inverse[1], inverse[2], inverse[4], inverse[5], inverse[6], inverse[8], inverse[9], inverse[10]]
}

private func ffMatrixVector(_ a: [Float], _ b: [Float]) -> [Float] {
    (0..<3).map { row in a[row * 3] * b[0] + a[row * 3 + 1] * b[1] + a[row * 3 + 2] * b[2] }
}

private func ffMatrixMultiply(_ a: [Float], _ b: [Float]) -> [Float] {
    (0..<9).map { index in
        let row = index / 3, col = index % 3
        return a[row * 3] * b[col] + a[row * 3 + 1] * b[3 + col] + a[row * 3 + 2] * b[6 + col]
    }
}

private func ffMatrixProduct(_ matrix: [Float], _ expression: String) -> String {
    "float3(" + (0..<3).map { row in
        "dot(float3(" + matrix[(row * 3)..<(row * 3 + 3)].map { ffNumber(Double($0)) }.joined(separator: ", ") + "), \(expression))"
    }.joined(separator: ", ") + ")"
}

extension FFJMhParameters {
    func rgbToAab(_ rgb: [Float]) -> [Float] {
        let response = ffMatrixVector(rgbToCAM, rgb).map { value -> Float in
            let power = pow(abs(value), Float(0.42))
            return (value < 0 ? -power : power) / (27.13 + power)
        }
        return ffMatrixVector(coneToAab, response)
    }

    func rgbToJMh(_ rgb: [Float]) -> [Float] {
        let aab = rgbToAab(rgb)
        if aab[0] <= 0 { return [0, 0, 0] }
        let j = 100 * pow(aab[0], cz)
        let m = sqrt(aab[1] * aab[1] + aab[2] * aab[2])
        var hue = 180 * atan2(aab[2], aab[1]) / Float.pi
        if hue < 0 { hue += 360 }
        return [j, m, hue]
    }

    func luminanceToJ(_ luminance: Float) -> Float {
        let compressed = pow(abs(luminance) * luminanceScale, Float(0.42))
        let response = compressed / (27.13 + compressed)
        let j = 100 * pow(response * (1 / whiteResponse), cz)
        return luminance < 0 ? -j : j
    }

    func jmhToRGB(j: Float, m: Float, hue: Float) -> [Float] {
        let radians = Float.pi * hue / 180
        let aab = [pow(j * 0.01, inverseCZ), m * cos(radians), m * sin(radians)]
        let response = ffMatrixVector(aabToCone, aab)
        let lms = response.map { value -> Float in
            let clamped = min(abs(value), Float(0.99))
            let result = pow(27.13 * clamped / (1 - clamped), Float(1) / Float(0.42))
            return value < 0 ? -result : result
        }
        return ffMatrixVector(camToRGB, lms)
    }
}

private func ffLerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + t * (b - a) }

private func ffFocus(_ j: Float, _ midJ: Float, _ maxJ: Float) -> Float {
    ffLerp(j, midJ, min(1, Float(1.3) - j / maxJ))
}

private func ffFocusGain(_ j: Float, _ threshold: Float, _ maxJ: Float, _ distance: Float) -> Float {
    var gain = maxJ * distance
    if j > threshold {
        let adjustment = log10((maxJ - threshold) / max(Float(0.0001), maxJ - j))
        gain *= adjustment * adjustment + 1
    }
    return gain
}

private func ffSolveIntersection(_ j: Float, _ m: Float, _ focus: Float, _ maxJ: Float, _ gain: Float) -> Float {
    let scaled = m / gain, a = scaled / focus
    if j < focus {
        let b = 1 - scaled, c = -j
        return -2 * c / (b + sqrt(b * b - 4 * a * c))
    }
    let b = -(1 + scaled + maxJ * a), c = maxJ * scaled + j
    return -2 * c / (b - sqrt(b * b - 4 * a * c))
}

private func ffGamutSlope(_ intersection: Float, _ focus: Float, _ maxJ: Float, _ gain: Float) -> Float {
    let scale = intersection < focus ? intersection : maxJ - intersection
    return scale * (intersection - focus) / (focus * gain)
}

private func ffBoundaryEstimate(_ intersection: Float, _ slope: Float, _ inverseGamma: Float,
                                _ maxJ: Float, _ maxM: Float, _ reference: Float) -> Float {
    let shifted = reference * pow(intersection / reference, inverseGamma)
    return shifted * maxM / (maxJ - slope * maxM)
}

private func ffBoundary(_ cusp: [Float], _ maxJ: Float, _ top: Float, _ bottom: Float,
                        _ source: Float, _ slope: Float, _ cuspIntersection: Float) -> Float {
    let lower = ffBoundaryEstimate(source, slope, bottom, cusp[0], cusp[1], cuspIntersection)
    let upper = ffBoundaryEstimate(maxJ - source, -slope, top, maxJ - cusp[0], cusp[1], maxJ - cuspIntersection)
    let scale = Float(0.12) * cusp[1]
    let h = max(scale - abs(lower - upper), 0) / scale
    return min(lower, upper) - h * h * h * scale * (Float(1) / 6)
}

private struct FFGamutParameters {
    let hueTable: [Float]
    let cuspTable: [[Float]]
    let midJ: Float
    let focusDistance: Float
    let lowerGammaInverse: Float

    init(peak: Float, input: FFJMhParameters, limiting: FFJMhParameters, reach: FFJMhParameters,
         tone: FFToneScaleParameters, limitJ: Float) throws {
        let mid = input.luminanceToJ(tone.grayTarget * 100)
        let distance = Float(1.35) + Float(1.35) * Float(1.75) * tone.logPeak
        let bottom = 1 / (Float(1.14) + Float(0.07) * tone.logPeak)
        midJ = mid
        focusDistance = distance
        lowerGammaInverse = bottom
        func corner(_ index: Int) -> [Float] {
            [Float((index + 1) % 6 < 3 ? 1 : 0), Float((index + 5) % 6 < 3 ? 1 : 0), Float((index + 3) % 6 < 3 ? 1 : 0)]
        }
        let rgbUnsorted = (0..<6).map { index in corner(index).map { $0 * (peak / 100) } }
        let jmhUnsorted = rgbUnsorted.map(limiting.rgbToJMh)
        guard jmhUnsorted.allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
            throw OCIOConfigError.invalid("ACES 2 limiting gamut has nonfinite corner values")
        }
        let first = (0..<6).min(by: { jmhUnsorted[$0][2] < jmhUnsorted[$1][2] })!
        var rgbCorners = (0..<6).map { rgbUnsorted[($0 + first) % 6] }
        var jmhCorners = (0..<6).map { jmhUnsorted[($0 + first) % 6] }
        rgbCorners.insert(rgbCorners[5], at: 0)
        rgbCorners.append(rgbCorners[1])
        jmhCorners.insert(jmhCorners[5], at: 0)
        jmhCorners.append(jmhCorners[1])
        jmhCorners[0][2] -= 360
        jmhCorners[7][2] += 360
        let limitA = pow(limitJ * 0.01, reach.inverseCZ)
        var reachHues: [Float] = []
        for index in 0..<6 {
            let vector = corner(index)
            var low: Float = 0, high = tone.forwardLimit
            while high - low > 0.001 {
                let test = (low + high) / 2
                if test == low || test == high { break }
                let a = reach.rgbToAab(vector.map { $0 * test })[0]
                if a < limitA { low = test } else { high = test }
                if a == limitA { break }
            }
            reachHues.append(reach.rgbToJMh(vector.map { $0 * high })[2])
        }
        let sortedHues = Array(Set(reachHues + jmhUnsorted.map { $0[2] })).sorted()
        guard !sortedHues.isEmpty, sortedHues.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 360 }) else {
            throw OCIOConfigError.invalid("ACES 2 gamut hue ordering is invalid")
        }
        var positions: [Int] = []
        var minimum = sortedHues[0] == 0 ? 0 : 1
        var last = -1
        for (index, hue) in sortedHues.enumerated() {
            var nominal = min(max(Int(hue.rounded(.toNearestOrAwayFromZero)), minimum), 359)
            if last == nominal {
                if index > 1 && positions[index - 2] != positions[index - 1] - 1 { positions[index - 1] -= 1 }
                else { nominal += 1 }
            }
            positions.append(min(nominal, 359))
            last = nominal
            minimum = nominal
        }
        var hues = [Float](repeating: 0, count: 363)
        var used = 0
        func interval(_ samples: Int, _ lower: Float, _ upper: Float) throws {
            guard samples >= 0, used + samples <= 360 else {
                throw OCIOConfigError.invalid("ACES 2 cusp hues exhaust the 360-sample table")
            }
            if samples > 0 {
                let delta = (upper - lower) / Float(samples)
                for index in 0..<samples { hues[used + index + 1] = lower + Float(index) * delta }
                used += samples
            }
        }
        try interval(positions[0], 0, sortedHues[0])
        for index in 1..<sortedHues.count { try interval(positions[index] - positions[index - 1], sortedHues[index - 1], sortedHues[index]) }
        try interval(360 - used, sortedHues.last!, 360)
        hues[0] = hues[360] - 360
        hues[361] = hues[1] + 360
        hues[362] = hues[2] + 360
        var cusps = [[Float]](repeating: [0, 0, 0], count: 363)
        var previousCorner = 0
        var previousFraction: Float = 0
        for index in 1...360 {
            let hue = hues[index]
            let upperCorner = (1..<8).first(where: { jmhCorners[$0][2] > hue }) ?? 1
            let lowerCorner = upperCorner - 1
            let jmh: [Float]
            if jmhCorners[lowerCorner][2] == hue { jmh = jmhCorners[lowerCorner] }
            else {
                var lower: Float = upperCorner == previousCorner ? previousFraction : 0
                var upper: Float = 1
                func sample(_ t: Float) -> [Float] {
                    limiting.rgbToJMh((0..<3).map { ffLerp(rgbCorners[lowerCorner][$0], rgbCorners[upperCorner][$0], t) })
                }
                while upper - lower > 0.0000001 {
                    let t = (lower + upper) / 2
                    if t == lower || t == upper { break }
                    let candidate = sample(t)
                    if candidate[2] < jmhCorners[lowerCorner][2] { upper = t }
                    else if candidate[2] >= jmhCorners[upperCorner][2] { lower = t }
                    else if candidate[2] > hue { upper = t }
                    else { lower = t }
                }
                let fraction = (lower + upper) / 2
                jmh = sample(fraction)
                previousCorner = upperCorner
                previousFraction = fraction
            }
            cusps[index] = [jmh[0], jmh[1] * (1 + Float(0.27) * Float(0.12)), hue]
        }
        for index in 1...360 {
            let cusp = cusps[index], hue = hues[index]
            let threshold = ffLerp(cusp[0], limitJ, 0.3)
            let focus = ffFocus(cusp[0], mid, limitJ)
            let tests: [(Float, Float, Float)] = [Float(0.01), 0.1, 0.5, 0.8, 0.99].map { position in
                let testJ = ffLerp(cusp[0], limitJ, position)
                let gain = ffFocusGain(testJ, threshold, limitJ, distance)
                let intersection = ffSolveIntersection(testJ, cusp[1], focus, limitJ, gain)
                return (intersection, ffGamutSlope(intersection, focus, limitJ, gain), ffSolveIntersection(cusp[0], cusp[1], focus, limitJ, gain))
            }
            func fits(_ gamma: Float) -> Bool {
                for (intersection, slope, cuspIntersection) in tests {
                    let m = ffBoundary(cusp, limitJ, 1 / gamma, bottom, intersection, slope, cuspIntersection)
                    let j = intersection + slope * m
                    if !limiting.jmhToRGB(j: j, m: m, hue: hue).contains(where: { $0 > peak / 100 }) { return false }
                }
                return true
            }
            var low: Float = 0, high: Float = 0.4
            while high < 5 && !fits(high) { low = high; high += 0.4 }
            while high - low > 0.00001 {
                let midpoint = (high + low) / 2
                if midpoint == low || midpoint == high { break }
                if fits(midpoint) { high = midpoint } else { low = midpoint }
            }
            cusps[index][2] = 1 / high
        }
        cusps[0] = cusps[360]
        cusps[361] = cusps[1]
        cusps[362] = cusps[2]
        hueTable = hues
        cuspTable = cusps
    }
}

extension OCIONativeCompiler {
    private mutating func fixedACES2Gamut(peak: Float, primaries: [Double], inverse: Bool) throws -> String {
        let input = try FFJMhParameters(primaries: [0.7347, 0.2653, 0, 1, 0.0001, -0.077, 0.32168, 0.33767])
        let reach = try FFJMhParameters(primaries: [0.713, 0.293, 0.165, 0.83, 0.128, 0.044, 0.32168, 0.33767])
        let limiting = try FFJMhParameters(primaries: primaries.map { Double(Float($0)) })
        let tone = FFToneScaleParameters(peak: peak)
        let maximumJ = input.luminanceToJ(peak)
        let gamut = try FFGamutParameters(peak: peak, input: input, limiting: limiting, reach: reach, tone: tone, limitJ: maximumJ)
        let reachIndex = textures.count
        textures.append(OCIONativeTexture(index: reachIndex, dimension: 1, width: 363, height: 1, depth: 1,
            channels: 1, values: ffReachTable(reach, limitJ: maximumJ)))
        let cuspIndex = textures.count
        let cuspValues = (0..<363).flatMap { gamut.cuspTable[$0] + [gamut.hueTable[$0]] }
        textures.append(OCIONativeTexture(index: cuspIndex, dimension: 1, width: 363, height: 1, depth: 1,
            channels: 4, values: cuspValues))
        let prefix = "ocio_ff_gamut_\(helperFunctions.count)"
        func f(_ value: Float) -> String { ffNumber(Double(value)) }
        let maxJ = f(maximumJ)
        let remap = inverse ? "if (nd >= 1.0f) return threshold + scale; return threshold + scale * -(nd / (nd - 1.0f));" : "return threshold + scale * nd / (1.0f + nd);"
        helperFunctions.append("""
        float \(prefix)_intersect(float J, float M, float focus, float gain) {
            float scaled = M / gain;
            float a = scaled / focus;
            if (J < focus) {
                float b = 1.0f - scaled;
                float c = -J;
                return -2.0f * c / (b + sqrt(b * b - 4.0f * a * c));
            }
            float b = -(1.0f + scaled + \(maxJ) * a);
            float c = \(maxJ) * scaled + J;
            return -2.0f * c / (b - sqrt(b * b - 4.0f * a * c));
        }
        float \(prefix)_boundary(float2 cusp, float top, float source, float reference, float slope) {
            float lower = reference * pow(source / reference, \(f(gamut.lowerGammaInverse))) / (cusp.r / cusp.g - slope);
            float upper = cusp.g * (\(maxJ) - reference) * pow((\(maxJ) - source) / (\(maxJ) - reference), top) / (slope * cusp.g + \(maxJ) - cusp.r);
            float scale = 0.12f * cusp.g;
            float h = max(scale - abs(lower - upper), 0.0f) / scale;
            return min(lower, upper) - h * h * h * scale * \(ffNumber(1 / 6));
        }
        float \(prefix)_remap(float M, float boundary, float reach) {
            float proportion = max(boundary / reach, 0.75f);
            float threshold = proportion * boundary;
            if (proportion >= 1.0f || M <= threshold) return M;
            float offset = M - threshold;
            float gamutOffset = boundary - threshold;
            float reachOffset = reach - threshold;
            float scale = reachOffset / (reachOffset / gamutOffset - 1.0f);
            float nd = offset / scale;
            \(remap)
        }
        float3 \(prefix)_compress(float3 JMh, float Jx, float3 cusp, float reachM) {
            float J = JMh.r, M = JMh.g;
            if (M <= 0.0f || J > \(maxJ)) return float3(J, 0.0f, JMh.b);
            float focus = mix(cusp.r, \(f(gamut.midJ)), min(1.0f, 1.3f - cusp.r / \(maxJ)));
            float threshold = mix(cusp.r, \(maxJ), 0.3f);
            float gain = \(f(maximumJ * gamut.focusDistance));
            if (Jx > threshold) {
                float adjustment = (\(maxJ) - threshold) / max(0.0001f, \(maxJ) - Jx);
                adjustment = log(adjustment) / log(10.0f);
                gain *= adjustment * adjustment + 1.0f;
            }
            float source = \(prefix)_intersect(J, M, focus, gain);
            float slope = source < focus ? source : \(maxJ) - source;
            slope *= (source - focus) / (focus * gain);
            float reference = \(prefix)_intersect(cusp.r, cusp.g, focus, gain);
            float boundary = \(prefix)_boundary(cusp.rg, cusp.b, source, reference, slope);
            if (boundary <= 0.0f) return float3(J, 0.0f, JMh.b);
            float reachBoundary = \(maxJ) * pow(source / \(maxJ), \(f(input.inverseCZ)));
            reachBoundary /= (\(maxJ) / reachM) - slope;
            float remapped = \(prefix)_remap(M, boundary, reachBoundary);
            return float3(source + remapped * slope, remapped, JMh.b);
        }
        """)
        var body = """
        {
            float hue = pixel.b - floor(pixel.b / 360.0f) * 360.0f;
            hue = hue < 0.0f ? hue + 360.0f : hue;
            pixel.b = hue;
            constexpr sampler tableSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
            float base = floor(hue);
            float reachLow = lut\(reachIndex).sample(tableSampler, (base + 1.5f) / 363.0f).r;
            float reachHigh = lut\(reachIndex).sample(tableSampler, (base + 2.5f) / 363.0f).r;
            float reachM = mix(reachLow, reachHigh, hue - base);
            int low = 0, high = 361;
            while (low + 1 < high) {
                int midpoint = (low + high) / 2;
                float currentHue = lut\(cuspIndex).sample(tableSampler, (float(midpoint) + 0.5f) / 363.0f).a;
                if (hue > currentHue) low = midpoint;
                else high = midpoint;
            }
            float4 lower = lut\(cuspIndex).sample(tableSampler, (float(high) - 0.5f) / 363.0f);
            float4 upper = lut\(cuspIndex).sample(tableSampler, (float(high) + 0.5f) / 363.0f);
            float3 cusp = mix(lower.rgb, upper.rgb, (hue - lower.a) / (upper.a - lower.a));
            float Jx = pixel.r;
        """
        if inverse {
            body += "if (Jx > mix(cusp.r, \(maxJ), 0.3f)) Jx = \(prefix)_compress(pixel.rgb, Jx, cusp, reachM).r;\n"
        }
        return body + "pixel.rgb = \(prefix)_compress(pixel.rgb, Jx, cusp, reachM); }"
    }
}

private struct FFToneScaleParameters {
    let s2: Float
    let m2: Float
    let inverseLimit: Float
    let forwardLimit: Float
    let grayTarget: Float
    let logPeak: Float

    init(peak n: Float) {
        let reference: Float = 100, g: Float = 1.15, toe: Float = 0.04
        let roof = 128 + (896 - 128) * (log(n / reference) / log(Float(10000) / 100))
        let m0 = n / reference
        let m1 = 0.5 * (m0 + sqrt(m0 * (m0 + 4 * toe)))
        let u = pow((roof / m1) / ((roof / m1) + 1), g)
        let m = m1 / u
        let wi = log(n / 100) / log(Float(2))
        let ct: Float = 10.013 / reference * (1 + wi * 0.14)
        let gip = 0.5 * (ct + sqrt(ct * (ct + 4 * toe)))
        let gipp2 = -(m1 * pow(gip / m, 1 / g)) / (pow(gip / m, 1 / g) - 1)
        let w2: Float = 0.18 / gipp2
        s2 = w2 * m1 * reference
        let u2 = pow((roof / m1) / ((roof / m1) + w2), g)
        m2 = m1 / u2
        inverseLimit = n / (u2 * reference)
        forwardLimit = 8 * roof
        grayTarget = ct
        logPeak = log10(n / reference)
    }
}

private func ffReachTable(_ parameters: FFJMhParameters, limitJ: Float) -> [Float] {
    var table = [Float](repeating: 0, count: 363)
    for hue in 0..<360 {
        var low: Float = 0, high: Float = 50
        while high < 1300 {
            if parameters.jmhToRGB(j: limitJ, m: high, hue: Float(hue)).contains(where: { $0 < 0 }) { break }
            low = high
            high += 50
        }
        while high - low > 0.01 {
            let midpoint = (high + low) / 2
            if parameters.jmhToRGB(j: limitJ, m: midpoint, hue: Float(hue)).contains(where: { $0 < 0 }) { high = midpoint }
            else { low = midpoint }
        }
        table[hue + 1] = high
    }
    table[0] = table[360]
    table[361] = table[1]
    table[362] = table[2]
    return table
}

extension OCIONativeCompiler {
    private mutating func fixedACES2ToneScale(peak: Float, inverse: Bool) throws -> String {
        let p = try FFJMhParameters(primaries: [0.7347, 0.2653, 0, 1, 0.0001, -0.077, 0.32168, 0.33767])
        let reach = try FFJMhParameters(primaries: [0.713, 0.293, 0.165, 0.83, 0.128, 0.044, 0.32168, 0.33767])
        let t = FFToneScaleParameters(peak: peak)
        let limitJ = p.luminanceToJ(peak)
        let lutIndex = textures.count
        textures.append(OCIONativeTexture(index: lutIndex, dimension: 1, width: 363, height: 1,
            depth: 1, channels: 1, values: ffReachTable(reach, limitJ: limitJ)))
        let prefix = "ocio_ff_tone_\(helperFunctions.count)"
        func f(_ value: Float) -> String { ffNumber(Double(value)) }
        let toeName = prefix + "_toe"
        let toneName = prefix + "_curve"
        let toeResult = inverse ? "(x * x + k1 * x) / (k3 * (x + k2))" : "0.5f * (k3 * x - k1 + sqrt((k3 * x - k1) * (k3 * x - k1) + 4.0f * k2 * k3 * x))"
        helperFunctions.append("""
        float \(toeName)(float x, float limit, float k1in, float k2in) {
            float k2 = max(k2in, 0.001f);
            float k1 = sqrt(k1in * k1in + k2 * k2);
            float k3 = (limit + k1) / (limit + k2);
            return (x > limit) ? x : \(toeResult);
        }
        """)
        var tone = "float \(toneName)(float J) { float A = \(f(p.whiteResponse)) * pow(abs(J) * 0.01f, \(f(p.inverseCZ))); float Y = pow(27.13f * A / (1.0f - A), \(ffNumber(1 / 0.42)));\n"
        if inverse {
            tone += "float Yi = Y / \(ffNumber(Double(p.luminanceScale) * 100)); float Z = max(0.0f, min(\(f(t.inverseLimit)), Yi)); float ht = 0.5f * (Z + sqrt(Z * (\(ffNumber(4 * Double(Float(0.04)))) + Z)));\n"
            tone += "float Yo = \(ffNumber(Double(p.luminanceScale) * Double(t.s2))) / (pow(\(f(t.m2)) / ht, \(ffNumber(1 / Double(Float(1.15))))) - 1.0f); float FLY = pow(abs(Yo), 0.42f);\n"
        } else {
            tone += "float f = \(f(t.m2)) * pow(Y / (Y + \(ffNumber(Double(t.s2) * Double(p.luminanceScale)))), 1.15f); float Yts = max(0.0f, f * f / (f + 0.04f)); float FLY = pow(\(ffNumber(Double(p.luminanceScale) * 100)) * Yts, 0.42f);\n"
        }
        tone += "float Jts = 100.0f * pow(FLY / (27.13f + FLY) * \(f(1 / p.whiteResponse)), \(f(p.cz))); return sign(J) * Jts; }"
        helperFunctions.append(tone)
        let sat = max(Float(0.2), Float(1.3) - (Float(1.3) * Float(0.69)) * t.logPeak)
        let satThreshold: Float = 0.5 / peak
        let compression = Float(2.4) + (Float(2.4) * Float(3.3)) * t.logPeak
        let chromaScale = pow(Float(0.03379) * peak, Float(0.30596)) - Float(0.45135)
        let cosineWeights = [11.34072, 16.46899, 7.88380].map { ffNumber($0 * Double(chromaScale)) }.joined(separator: ",")
        let sineWeights = [14.66441, -6.37224, 9.19364].map { ffNumber($0 * Double(chromaScale)) }.joined(separator: ",")
        var result = """
        {
            float hue = pixel.b - floor(pixel.b / 360.0f) * 360.0f;
            hue = hue < 0.0f ? hue + 360.0f : hue;
            float angle = hue * \(f(Float.pi / 180));
            float cosine = cos(angle), sine = sin(angle);
            constexpr sampler reachSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
            float base = floor(hue);
            float reachLow = lut\(lutIndex).sample(reachSampler, (base + 1.5f) / 363.0f).r;
            float reachHigh = lut\(lutIndex).sample(reachSampler, (base + 2.5f) / 363.0f).r;
            float reachM = mix(reachLow, reachHigh, hue - base);
            float originalJ = pixel.r;
            float convertedJ = \(toneName)(originalJ);
            float M = pixel.g;
            if (M != 0.0f) {
                float nJ = \(inverse ? "originalJ" : "convertedJ") / \(f(limitJ));
                float snJ = max(0.0f, 1.0f - nJ);
                float3 cosines = float3(cosine, 2.0f * cosine * cosine - 1.0f, 4.0f * cosine * cosine * cosine - 3.0f * cosine);
                float3 sines = float3(sine, 2.0f * cosine * sine, 3.0f * sine - 4.0f * sine * sine * sine);
                float Mnorm = dot(cosines, float3(\(cosineWeights))) + dot(sines, float3(\(sineWeights))) + \(ffNumber(77.12896 * Double(chromaScale)));
                float limit = pow(nJ, \(f(p.inverseCZ))) * reachM / Mnorm;
        """
        if inverse {
            result += """
                    M /= Mnorm;
                    M = \(toeName)(M, limit, nJ * \(f(compression)), snJ);
                    M = limit - \(toeName)(limit - M, limit - 0.001f, snJ * \(f(sat)), sqrt(nJ * nJ + \(f(satThreshold))));
                    M *= Mnorm;
                    M *= pow(originalJ / convertedJ, \(f(-p.inverseCZ)));
            """
        } else {
            result += """
                    M *= pow(convertedJ / originalJ, \(f(p.inverseCZ)));
                    M /= Mnorm;
                    M = limit - \(toeName)(limit - M, limit - 0.001f, snJ * \(f(sat)), sqrt(nJ * nJ + \(f(satThreshold))));
                    M = \(toeName)(M, limit, nJ * \(f(compression)), snJ);
                    M *= Mnorm;
            """
        }
        return result + "} pixel.rgb = float3(convertedJ, M, hue); }"
    }
}
