/// one Ray with origin, direction, and strength
struct InitRay {
  o: vec3<f32>;
  wavelength: f32;
  d: vec3<f32>;
  strength: f32;
};

struct Ray {
  o: vec3<f32>;
  wavelength: f32;
  d: vec3<f32>;
  strength: f32;
  aperture_pos: vec2<f32>;
};

struct DrawRay {
    pos: vec2<f32>;
    aperture_pos: vec2<f32>;
    strength: f32;
    wavelength: f32;
};

/// one Lens Element 
/// - one optical interface between glass and air
struct Element {
  radius: f32;
  b1: f32;
  b2: f32;
  b3: f32;
  c1: f32;
  c2: f32;
  c3: f32;
  b1_2: f32;
  b2_2: f32;
  b3_2: f32;
  c1_2: f32;
  c2_2: f32;
  c3_2: f32;
  coating_ior: f32;
  coating_thickness: f32;
  position: f32;// num_blades if aperture
  entry: f32;// 0: false, 1: true, 2: aperture
  spherical: f32;// 0: false, 1: true
};


struct SimParams {
  opacity: f32;
  width_scaled: f32;
  height_scaled: f32;
  width: f32;
  height: f32;
  draw_mode: f32;
  which_ghost: f32;
  window_width_scaled: f32;
  window_height_scaled: f32;
  window_width: f32;
  window_height: f32;
  side_len: f32;
};


struct WhichGhost {
  i: u32;
  j: u32;
};


// static parameters for positions
struct PosParams {
  // the Ray to be modified as a base for ray tracing
  init: InitRay;
  // position of the sensor in the optical plane
  sensor: f32;
  width: f32;
};


struct Rays {
  rays: [[stride(24)]] array<DrawRay>;
};


/// all the Elements of the Lens under test
struct Elements {
  el: [[stride(72)]] array<Element>;
};

/// all the Elements of the Lens under test
struct Ghosts {
  el: [[stride(8)]] array<WhichGhost>;
};

[[group(0), binding(0)]] var<storage, read_write> rays : Rays;
[[group(2), binding(2)]] var<uniform> params : SimParams;

[[group(2), binding(0)]] var<uniform> posParams : PosParams;

[[group(1), binding(2)]] var<storage, read> whichGhost : Ghosts;

[[group(1), binding(0)]] var<storage, read> elements : Elements;

fn plank(wavelen: f32, temp: f32) -> f32 {
    let h = 6.62607015e-34; // J/Hz
    let b = 1.380649e-23; // J/K
    let c = 299792458.; // m/s
    let e = 2.718281828459045;
    let hc = 1.9864458571489286e-25;
    let hcc2 = 1.1910429723971884e-16;
    return hcc2
        / (pow(wavelen, 5.))
        / (pow(e, (hc) / (wavelen * b * temp)) - 1.) / 1.e12;
}

fn str_from_wavelen(wavelen: f32) -> f32 {
    return plank(wavelen / 1000000., 3000.) * 10.;
}

fn ior(self: Element, wavelength: f32) -> f32 {
    let wavelength_sq = wavelength * wavelength;
    let n_sq = 1. + (self.b1 * wavelength_sq) / (wavelength_sq - self.c1)
                      + (self.b2 * wavelength_sq) / (wavelength_sq - self.c2)
                      + (self.b3 * wavelength_sq) / (wavelength_sq - self.c3);
    return sqrt(n_sq);
}

fn ior_other(self: Element, wavelength: f32) -> f32 {
    let wavelength_sq = wavelength * wavelength;
    let n_sq = 1. + (self.b1_2 * wavelength_sq) / (wavelength_sq - self.c1_2)
                      + (self.b2_2 * wavelength_sq) / (wavelength_sq - self.c2_2)
                      + (self.b3_2 * wavelength_sq) / (wavelength_sq - self.c3_2);
    return sqrt(n_sq);
}

/// calculate the fresnel term for an intersection
fn fresnel_r(t1: f32, t2: f32, n1: f32, n2: f32) -> f32 {
  let s = 0.5 * ((n1 * cos(t1) - n2 * cos(t2)) / (n1 * cos(t1) + n2 * cos(t2))) * ((n1 * cos(t1) - n2 * cos(t2)) / (n1 * cos(t1) + n2 * cos(t2)));
  let p = 0.5 * ((n1 * cos(t2) - n2 * cos(t1)) / (n1 * cos(t2) + n2 * cos(t1))) * ((n1 * cos(t2) - n2 * cos(t1)) / (n1 * cos(t2) + n2 * cos(t1)));
  return s + p;
}

fn fresnel_ar(theta0: f32, lambda: f32, thickness: f32, n0: f32, n1: f32, n2: f32) -> f32 {
    let theta0_fixed = max(theta0, 0.001);
    // refracton angle sin coating and the 2nd medium
    let theta1 = asin(sin(theta0_fixed) * n0 / n1);
    let theta2 = asin(sin(theta0_fixed) * n0 / n2);
    // amplitude for outer refl. / transmission on topmost interface
    let rs01 = -sin(theta0_fixed - theta1) / sin(theta0_fixed + theta1);
    let rp01 = tan(theta0_fixed - theta1) / tan(theta0_fixed + theta1);
    let ts01 = 2. * sin(theta1) * cos(theta0_fixed) / sin(theta0_fixed + theta1);
    let tp01 = ts01 * cos(theta0_fixed - theta1);
    // amplitude for inner reflection
    let rs12 = -sin(theta1 - theta2) / sin(theta1 + theta2);
    let rp12 = tan(theta1 - theta2) / tan(theta1 + theta2);
    // after passing through first surface twice:
    // 2 transmissions and 1 reflection
    let ris = ts01 * ts01 * rs12;
    let rip = tp01 * tp01 * rp12;
    // phasedifference between outer and inner reflections
    let dy = thickness * n1;
    let dx = tan(theta1) * dy;
    let delay = sqrt(dx * dx + dy * dy);
    let rel_phase = 4. * 3.141592653589793 / lambda * (delay - dx * sin(theta0_fixed));
    // Add up sines of different phase and amplitude
    let out_s2 = rs01 * rs01 + ris * ris + 2. * rs01 * ris * cos(rel_phase);
    let out_p2 = rp01 * rp01 + rip * rip + 2. * rp01 * rip * cos(rel_phase);
    return (out_s2 + out_p2) / 2.; // reflectivity
}

/// the main ray tracing function - propagates a Ray to the given Element and
/// returns a new Ray at that intersection in the direction after the Element
fn propagate_element(
    self: Ray,
    radius: f32,
    ior: f32,
    other_ior: f32,
    position: f32,
    reflect: bool,
    entry: bool,
    cylindrical: bool,
    coating_ior: f32,
    coating_thickness: f32,
) -> Ray {
    var ray = self;
    ray.d = normalize(ray.d);
    var intersection: vec3<f32>;
    // calculate the intersection point
    if (cylindrical) {
        // cylindrical: x is not affected by curvature

        // c: center of the lens surface if interpreted as an entire sphere
        var cy: f32;
        if (entry) {
            cy = position + radius;
        } else {
            cy = position - radius;
        };
        let c = vec2<f32>(0., cy);
        let o = vec2<f32>(ray.o.x,ray.o.z);
        let d = normalize(vec2<f32>(ray.d.x, ray.d.z));
        let delta = dot(d, o - c) * dot(d, o - c)
                    - (length(o - c) * length(o - c) - radius * radius);

        let d1 = -(dot(d, o - c)) - sqrt(delta);
        let d2 = -(dot(d, o - c)) + sqrt(delta);

        if ((entry == (ray.d.z > 0.)) == (radius > 0.)) {
            intersection = ray.o + ray.d * d1;
        } else {
            intersection = ray.o + ray.d * d2;
        }
    } else {
        // c: center of the lens surface if interpreted as an entire sphere
        var cz: f32;
        if (entry) {
            cz = position + radius;
        } else {
            cz = position - radius;
        };
        let c = vec3<f32>(0., 0., cz);

        let delta = dot(ray.d, ray.o - c) * dot(ray.d, ray.o - c)
                    - (length(ray.o - c) * length(ray.o - c) - radius * radius);

        let d1 = -(dot(ray.d, ray.o - c)) - sqrt(delta);
        let d2 = -(dot(ray.d, ray.o - c)) + sqrt(delta);

        if ((entry == (ray.d.z > 0.)) == (radius > 0.)) {
            intersection = ray.o + ray.d * d1;
        } else {
            intersection = ray.o + ray.d * d2;
        }
    };

    ray.o = intersection;

    var normal: vec3<f32>;
    // calculate the normal at the intersection
    if (cylindrical) {
        var cy: f32;
        if (entry) {
            cy = position + radius;
        } else {
            cy = position - radius;
        };
        let c = vec2<f32>(0., cy);

        let intersection_2d = vec2<f32>(intersection.x, intersection.z);

        let normal2d = intersection_2d - c;

        let intersection_3d = vec3<f32> (0.0, normal2d.x, normal2d.y);

        if ((entry == (ray.d.z > 0.)) == (radius > 0.)) {
            normal = normalize(intersection_3d);
        } else {
            normal = -(normalize(intersection_3d));
        }
    } else {
        var cz: f32;
        if (entry) {
            cz = position + radius;
        } else {
            cz = position - radius;
        };
        let c = vec3<f32>(0., 0., cz);

        if ((entry == (ray.d.z > 0.)) == (radius > 0.)) {
            normal = normalize((intersection - c));
        } else {
            normal = -(normalize(intersection - c));
        }
    };

    // calculate the new direction of the Ray
    if (reflect) {
        let d_in = ray.d;

        ray.d = ray.d - 2.0 * dot(normal, ray.d) * normal;

        var a: f32;
        if (entry == (ray.d.z > 0.)) {
            a = ior;
        } else {
            a = other_ior;
        };
        var b: f32;
        if (entry == (ray.d.z > 0.)) {
            b = other_ior;
        } else {
            b = ior;
        }

        ray.strength = ray.strength * fresnel_ar(
                acos(dot(normalize(d_in), -normal)),
                ray.wavelength,
                coating_thickness,
                b,
                coating_ior,
                a,
            );
    } else {
        var eta: f32;
        if (entry) { eta = 1.0 / ior; } else { eta = ior; };

        // from https://www.khronos.org/registry/OpenGL-Refpages/gl4/html/refract.xhtml
        let k = 1.0 - eta * eta * (1.0 - dot(normal, ray.d) * dot(normal, ray.d));

        let d_in = ray.d;

        if (k < 0.0) {
            // total reflection
            // println!("total reflection");
            ray.d = ray.d * 0.0; // or genDType(0.0)
        } else {
            ray.d = eta * ray.d - (eta * dot(normal, ray.d) + sqrt(k)) * normal;
        }

        var a: f32;
        if (entry == (ray.d.z > 0.)) {
            a = ior;
        } else {
            a = other_ior;
        };
        var b: f32;
        if (entry == (ray.d.z > 0.)) {
            b = other_ior;
        } else {
            b = ior;
        }
        ray.strength = ray.strength * (1.0
            - fresnel_ar(
                acos(dot(normalize(d_in), -normal)),
                ray.wavelength,
                coating_thickness,
                b,
                coating_ior,
                a,
            ));
    }
    return ray;
}

// intersect a ray with the sensor / any plane on the optical axis
fn intersect_ray_to_ray(self: Ray, plane: f32) -> Ray {
    let diff = plane - self.o.z;
    let num_z = diff / self.d.z;

    let intersect = self.o + self.d * num_z;
    var ray = self;
    ray.aperture_pos.x = intersect.x;
    ray.aperture_pos.y = intersect.y;
    return ray;
}

/// propagate a ray through an element
///
fn propagate(self: Ray, element: Element) -> Ray {
    if (element.entry > 1.) {
        // var ray = self;
        // // ray.strength = self.strength * f32(u32(clip_ray_poly(self, u32(element.position), element.radius)));
        // let pass = !clip_ray_poly(self, element.position, u32(element.b1), element.radius);
        // ray.strength = self.strength * f32(u32(pass));
        // ray.aperture_pos = 
        return intersect_ray_to_ray(self, element.position);
    } else {
        return propagate_element(
            self,
            element.radius,
            ior(element, self.wavelength),
            ior_other(element, self.wavelength),
            element.position,
            false,
            element.entry > 0.,
            !(element.spherical > 0.),
            element.coating_ior,
            element.coating_thickness,
        );
    }
}

/// reflect a Ray from an element
///
fn reflect_ray(self: Ray, element: Element) -> Ray {
    return propagate_element(
        self,
        element.radius,
        ior(element, self.wavelength),
        ior_other(element, self.wavelength),
        element.position,
        true,
        element.entry > 0.,
        !(element.spherical > 0.),
        element.coating_ior,
        element.coating_thickness,
    );
}

// intersect a ray with the sensor / any plane on the optical axis
fn intersect_ray(self: Ray, plane: f32) -> Ray {
    let diff = plane - self.o.z;
    let num_z = diff / self.d.z;

    let intersect = self.o + self.d * num_z;
    var ray = self;
    ray.o.x = intersect.x;
    ray.o.y = intersect.y;
    return ray;
}

fn drawRay_from_Ray(self: Ray) -> DrawRay {
    return DrawRay(self.o.xy, self.aperture_pos.xy, self.strength, self.wavelength);
}

[[stage(compute), workgroup_size(64)]]
fn main([[builtin(global_invocation_id)]] global_invocation_id: vec3<u32>) {
  let draw_mode = u32(params.draw_mode);//u32(1);
  let which_ghost = u32(params.which_ghost);//u32(1);

  // the total number of possible shader executions
  let total = arrayLength(&rays.rays);
  let index = global_invocation_id.x % (u32(params.side_len) * u32(params.side_len));
  let ghost_num = global_invocation_id.x / (u32(params.side_len) * u32(params.side_len));
//   for (var i = u32(0); i < arrayLength(&rays.rays) - u32(1); i = i + u32(1)) {
//     rays.rays[i] = DrawRay(vec2<f32>(f32(global_invocation_id.x), f32(global_invocation_id.y)), vec2<f32>(0., 0.), 1., params.side_len);
//   }
  if (global_invocation_id.x >= total) { // if we don't fit in the buffer - return early
    return;
  }

  let num_rays = total;
  let ray_num = index;

  // how much to move the rays by to sample
  let width = posParams.width;

  // we need the sqrt to scale the movement in each direction by
  let sqrt_num = u32(params.side_len);//u32(sqrt(f32(num_rays)) + 0.5);
  let ray_num_x = f32(ray_num / sqrt_num);
  let ray_num_y = f32(ray_num % sqrt_num);

  // how many dots have we added to the buffer
  var counter = u32(0);
  if ((draw_mode & u32(1)) > u32(0)) {
    let i = whichGhost.el[ghost_num].i;
    let j = whichGhost.el[ghost_num].j;
    if(i == u32(0) && j == u32(0)) {
        return;
    }
        // make new ray
        var dir = posParams.init.d;
        // modify both directions according to our index
        dir.x = dir.x + (ray_num_x / f32(sqrt_num) * width - width / 2.);
        dir.y = dir.y + (ray_num_y / f32(sqrt_num) * width - width / 2.);
        dir = normalize(dir);
        let wavelength = 0.5;
        var ray = Ray(posParams.init.o, wavelength, dir, str_from_wavelen(wavelength), vec2<f32>(0., 0.));

        for (var ele = u32(0); ele < arrayLength(&elements.el); ele = ele + u32(1)) {
            let element = elements.el[ele];
            // if we iterated through all elements up to
            // the first reflection point

            if (ele == j) {
                // reflect at the first element,
                // which is further down the optical path
                ray = reflect_ray(ray, element);

                // propagate backwards through system
                // until the second reflection
                for (var k = j - u32(1); k > i; k = k - u32(1)) { // for k in (i + 1..j).rev() {
                    ray = propagate(ray, elements.el[k]);
                }
                ray = reflect_ray(ray, elements.el[i]);

                for (var k = i + u32(1); k <= j; k = k + u32(1)) { // for k in i + 1..=j {
                    ray = propagate(ray, elements.el[k]);
                }
                // println!("strength: {}", ray.strength);
            } else {
                ray = propagate(ray, element);
            }
        }
        ray = intersect_ray(ray, posParams.sensor);

        // only return rays that have made it through
        rays.rays[ray_num + ghost_num * (u32(params.side_len) * u32(params.side_len))] = drawRay_from_Ray(ray);
        // counter = counter + u32(1);
  }
  // if we want to draw normally
  if ((draw_mode & u32(2)) > u32(0)) {
    // make new ray
    var dir = posParams.init.d;
    // modify both directions according to our index
    dir.x = dir.x + (ray_num_x / f32(sqrt_num) * width - width / 2.);
    dir.y = dir.y + (ray_num_y / f32(sqrt_num) * width - width / 2.);
    dir = normalize(dir);
    let wavelength = 0.5;
    var ray = Ray(posParams.init.o, wavelength, dir, str_from_wavelen(wavelength), vec2<f32>(0., 0.));
    // iterate through all Elements and propagate the Ray through
    for (var i: u32 = u32(0); i < arrayLength(&elements.el); i = i + u32(1)) {
        let element = elements.el[i];
        ray = propagate(ray, element);
    }
    // intersect the ray with the sensor
    ray = intersect_ray(ray, posParams.sensor);
    // save the Ray in the current buffer position
    rays.rays[ray_num + ghost_num * (u32(params.side_len) * u32(params.side_len))] = drawRay_from_Ray(ray);
  }
}