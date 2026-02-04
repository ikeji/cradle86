const DEBUG = false
const DEFAULT = true

// Library {{{

// Modified at 20251024

function _genRandomColor() {
  const COLORS=["blue","orange","green","red"];
  if (!_genRandomColor.colorIndex) {
    _genRandomColor.colorIndex = 0;
  }
  const c = COLORS[_genRandomColor.colorIndex];
  _genRandomColor.colorIndex++;
  if (_genRandomColor.colorIndex >= COLORS.length) {
    _genRandomColor.colorIndex=0;
  }
  // console.log(_genRandomColor.colorIndex);
  // console.log(c);
  return c;
}

class CadObjectM {
  constructor(shape=null, color=null, name="", opacity = 1){
    this._shape = shape;
    this._color = color;
    this._name = name;
    this._opacity = opacity;
  }
  shape(){
    return this._shape;
  }
  color(){
    return this._color;
  }
  name() {
    return this._name;
  }
  opacity() {
    return this._opacity;
  }
  emptyp() {
    return !this._shape;
  }

  move(x,y,z){
    if (this.emptyp()){
      return this;
    }
    return new CadObjectM(
      this.shape().translate(x,y,z),
      this.color(),
      this.name(),
      this.opacity())
  }
  scale(s){
    if (this.emptyp()){
      return this;
    }
    return new CadObjectM(
      this.shape().scale(s),
      this.color(),
      this.name(),
      this.opacity())
  }
  rotateX(d){
    if (this.emptyp()){
      return this;
    }
    return new CadObjectM(
      this.shape().rotate(
        d,
        [0,0,0],
        [1,0,0]
      ),
      this.color(),
      this.name(),
      this.opacity())
  }
  rotateY(d){
    if (this.emptyp()){
      return this;
    }
    return new CadObjectM(
      this.shape().rotate(
        d,
        [0,0,0],
        [0,1,0]
      ),
      this.color(),
      this.name(),
      this.opacity())
  }
  rotateZ(d){
    if (this.emptyp()){
      return this;
    }
    return new CadObjectM(
      this.shape().rotate(
        d,
        [0,0,0],
        [0,0,1]
      ),
      this.color(),
      this.name(),
      this.opacity())
  }
  mirrorX(){
    if (this.emptyp()){
      return this;
    }
    return new CadObjectM(
      this.shape().mirror("YZ"),
      this.color(),
      this.name(),
      this.opacity())
  }
  mirrorY(){
    if (this.emptyp()){
      return this;
    }
    return new CadObjectM(
      this.shape().mirror("XZ"),
      this.color(),
      this.name(),
      this.opacity())
  }
  mirrorZ(){
    if (this.emptyp()){
      return this;
    }
    return new CadObjectM(
      this.shape().mirror("XY"),
      this.color(),
      this.name(),
      this.opacity())
  }

  union(they){
    if (this.emptyp()){
      return they;
    }
    if (they.emptyp()){
      return this;
    }
    return new CadObjectM(
      this.shape().fuse(they.shape()),
      this.color(),
      this.name(),
      this.opacity())
  }
  cut(they) {
    if (this.emptyp()){
      return this;
    }
    if (they.emptyp()){
      return this;
    }
    return new CadObjectM(
      this.shape().cut(they.shape()),
      this.color(),
      this.name(),
      this.opacity())
  }
  intersect(they) {
    if (this.emptyp()){
      return this;
    }
    if (they.emptyp()){
      return they;
    }
    return new CadObjectM(
      this.shape().intersect(they.shape()),
      this.color(),
      this.name(),
      this.opacity())
  }

  fillet(s,f) {
    if (this.emptyp()){
      return this;
    }
    return new CadObjectM(
      this.shape().fillet(s,f),
      this.color(),
      this.name(),
      this.opacity())
  }
  chamfer(s,f) {
    if (this.emptyp()){
      return this;
    }
    return new CadObjectM(
      this.shape().chamfer(s,f),
      this.color(),
      this.name(),
      this.opacity())
  }
  asymmetricChamfer(edge, face1, size1, size2) {
    if (this.emptyp()){
      return this;
    }
    return new CadObjectM(
      this.shape().chamfer({
        distances: [ size1, size2 ],
        selectedFace: face1,
      },edge),
      this.color(),
      this.name(),
      this.opacity())
  }
  apply(f) {
    return f(this);
  }
}

function box(x, y, z) {
  return new CadObjectM(
    replicad.makeBaseBox(x,y,z).translate(x/2,y/2,0));
}

function sphere(r) {
  return new CadObjectM(
    replicad.makeSphere(r/2));
}

function cylinder(r, h) {
  return new CadObjectM(
    replicad.makeCylinder(r/2,h));
}

function text(message, size) {
  return new CadObjectM(
    replicad.drawText(message, {fontSize: size})
    .sketchOnPlane()
    .extrude(1));
}

function axises() {
  const axisLength = 100;
  const axisThickness = 1;
  const labelSize = 5;

  const xAxisObj = box(axisLength, axisThickness, axisThickness)
                  .move(-axisLength / 2, -axisThickness / 2, 0);
  const yAxisObj = box(axisThickness, axisLength, axisThickness)
                  .move(-axisThickness / 2, -axisLength / 2, 0);
  const zAxisObj = box(axisThickness, axisThickness, axisLength)
                  .move(-axisThickness / 2, -axisThickness / 2, -axisLength / 2);

  const xAxis = new CadObjectM(xAxisObj.shape(), "red", "X-Axis");
  const yAxis = new CadObjectM(yAxisObj.shape(), "green", "Y-Axis");
  const zAxis = new CadObjectM(zAxisObj.shape(), "blue", "Z-Axis");

  const xLabelP = text("X+", labelSize).move(axisLength / 2 + 5, -labelSize / 2, 0);
  const xLabelN = text("X-", labelSize).move(-axisLength / 2 - 15, -labelSize / 2, 0);
  const yLabelP = text("Y+", labelSize).move(-labelSize / 2, axisLength / 2 + 5, 0);
  const yLabelN = text("Y-", labelSize).move(-labelSize / 2, -axisLength / 2 - 15, 0);
  const zLabelP = text("Z+", labelSize).rotateX(90).move(-labelSize / 2, 0, axisLength / 2 + 5);
  const zLabelN = text("Z-", labelSize).rotateX(90).move(-labelSize / 2, 0, -axisLength / 2 - 5);

  return union([xAxis, yAxis, zAxis, xLabelP, xLabelN, yLabelP, yLabelN, zLabelP, zLabelN]);
}


function empty(){
  return new CadObjectM();
}

function debug(fn) {
  if (DEBUG){
    return empty();
  }else{
    return fn();
  }
}

function union(objs) {
  if (objs.length == 0) return empty();
  let rv = objs[0];
  for (let i=1;i<objs.length;i++) {
    rv = rv.union(objs[i]);
  }
  return rv;
}

function intersect(objs) {
  if (objs.length == 0) return empty();
  let rv = objs[0];
  for (let i=1;i<objs.length;i++) {
    rv = rv.intersect(objs[i]);
  }
  return rv;
}

/**
 * Represents a 3x3 matrix for transformations.
 */
class Matrix3x3 {
  /**
   * Creates an instance of Matrix3x3, initialized as an identity matrix.
   */
  constructor() {
    // Identity matrix
    this.m = [
      1, 0, 0,
      0, 1, 0,
      0, 0, 1
    ];
  }

  /**
   * Creates a rotation matrix for rotation around the X-axis.
   * @param {number} d - The rotation angle in degrees.
   * @returns {Matrix3x3} A new rotation matrix.
   */
  static rotationX(d) {
    const r = d * Math.PI / 180;
    const cos = Math.cos(r);
    const sin = Math.sin(r);
    const mat = new Matrix3x3();
    mat.m = [
      1, 0, 0,
      0, cos, -sin,
      0, sin, cos
    ];
    return mat;
  }

  /**
   * Creates a rotation matrix for rotation around the Y-axis.
   * @param {number} d - The rotation angle in degrees.
   * @returns {Matrix3x3} A new rotation matrix.
   */
  static rotationY(d) {
    const r = d * Math.PI / 180;
    const cos = Math.cos(r);
    const sin = Math.sin(r);
    const mat = new Matrix3x3();
    mat.m = [
      cos, 0, sin,
      0, 1, 0,
      -sin, 0, cos
    ];
    return mat;
  }

  /**
   * Creates a rotation matrix for rotation around the Z-axis.
   * @param {number} d - The rotation angle in degrees.
   * @returns {Matrix3x3} A new rotation matrix.
   */
  static rotationZ(d) {
    const r = d * Math.PI / 180;
    const cos = Math.cos(r);
    const sin = Math.sin(r);
    const mat = new Matrix3x3();
    mat.m = [
      cos, -sin, 0,
      sin, cos, 0,
      0, 0, 1
    ];
    return mat;
  }

  /**
   * Multiplies this matrix by another matrix.
   * @param {Matrix3x3} other - The matrix to multiply by.
   * @returns {Matrix3x3} The resulting matrix.
   */
  multiply(other) {
    const result = new Matrix3x3();
    const a = this.m;
    const b = other.m;
    const r = new Array(9);

    r[0] = a[0] * b[0] + a[1] * b[3] + a[2] * b[6];
    r[1] = a[0] * b[1] + a[1] * b[4] + a[2] * b[7];
    r[2] = a[0] * b[2] + a[1] * b[5] + a[2] * b[8];

    r[3] = a[3] * b[0] + a[4] * b[3] + a[5] * b[6];
    r[4] = a[3] * b[1] + a[4] * b[4] + a[5] * b[7];
    r[5] = a[3] * b[2] + a[4] * b[5] + a[5] * b[8];

    r[6] = a[6] * b[0] + a[7] * b[3] + a[8] * b[6];
    r[7] = a[6] * b[1] + a[7] * b[4] + a[8] * b[7];
    r[8] = a[6] * b[2] + a[7] * b[5] + a[8] * b[8];
    
    result.m = r;
    return result;
  }

  /**
   * Checks if this matrix is equal to another matrix.
   * @param {Matrix3x3} other - The matrix to compare with.
   * @param {number} [tolerance=1e-9] - The tolerance for floating-point comparisons.
   * @returns {boolean} True if the matrices are equal, false otherwise.
   */
  equals(other, tolerance = 1e-9) {
    if (!other || !(other instanceof Matrix3x3)) {
      return false;
    }
    for (let i = 0; i < 9; i++) {
      if (Math.abs(this.m[i] - other.m[i]) > tolerance) {
        return false;
      }
    }
    return true;
  }

  /**
   * Converts the rotation matrix to Euler angles.
   * @returns {{yaw: number, pitch: number, roll: number}} The Euler angles in degrees.
   */
  toEulerAngles() {
    const radToDeg = 180 / Math.PI;
    const m = this.m;
    let pitch, yaw, roll;

    // Corresponds to R = Rz(yaw) * Ry(pitch) * Rx(roll)
    const sinPitch = -m[6];
    if (Math.abs(sinPitch) >= 1) { // Gimbal lock
        pitch = Math.PI / 2 * (sinPitch > 0 ? 1 : -1);
        yaw = Math.atan2(-m[1], m[4]);
        roll = 0;
    } else {
        pitch = Math.asin(sinPitch);
        yaw = Math.atan2(m[3], m[0]);
        roll = Math.atan2(m[7], m[8]);
    }

    return {
        yaw: yaw * radToDeg,
        pitch: pitch * radToDeg,
        roll: roll * radToDeg
    };
  }
}

/**
 * Represents a point in 3D space.
 */
class Point3D {
  /**
   * The origin point (0, 0, 0).
   * @type {Point3D}
   */
  static ZERO = new Point3D(0, 0, 0);

  /**
   * Creates an instance of Point3D.
   * @param {number} x - The x-coordinate.
   * @param {number} y - The y-coordinate.
   * @param {number} z - The z-coordinate.
   */
  constructor(x, y, z) {
    this.x = x;
    this.y = y;
    this.z = z;
  }

  /**
   * Moves the point by a given offset.
   * @param {number} x - The offset in the x-direction.
   * @param {number} y - The offset in the y-direction.
   * @param {number} z - The offset in the z-direction.
   * @returns {Point3D} A new Point3D instance with the updated coordinates.
   */
  move(x, y, z) {
    return new Point3D(this.x + x, this.y + y, this.z + z);
  }

  /**
   * Applies a transformation matrix to the point.
   * @param {Matrix3x3} matrix - The transformation matrix.
   * @returns {Point3D} A new Point3D instance after transformation.
   */
  transform(matrix) {
    const x = matrix.m[0] * this.x + matrix.m[1] * this.y + matrix.m[2] * this.z;
    const y = matrix.m[3] * this.x + matrix.m[4] * this.y + matrix.m[5] * this.z;
    const z = matrix.m[6] * this.x + matrix.m[7] * this.y + matrix.m[8] * this.z;
    return new Point3D(x, y, z);
  }

  /**
   * Rotates the point around the X-axis.
   * @param {number} d - The rotation angle in degrees.
   * @returns {Point3D} A new Point3D instance after rotation.
   */
  rotateX(d){
    return this.transform(Matrix3x3.rotationX(d));
  }
  /**
   * Rotates the point around the Y-axis.
   * @param {number} d - The rotation angle in degrees.
   * @returns {Point3D} A new Point3D instance after rotation.
   */
  rotateY(d){
    return this.transform(Matrix3x3.rotationY(d));
  }
  /**
   * Rotates the point around the Z-axis.
   * @param {number} d - The rotation angle in degrees.
   * @returns {Point3D} A new Point3D instance after rotation.
   */
  rotateZ(d){
    return this.transform(Matrix3x3.rotationZ(d));
  }

  /**
   * Checks if this point is equal to another point.
   * @param {Point3D} other - The point to compare with.
   * @returns {boolean} True if the points are equal, false otherwise.
   */
  equals(other, tolerance = 1e-9) {
    if (!other || !(other instanceof Point3D)) {
      return false;
    }
    return (
      Math.abs(this.x - other.x) < tolerance &&
      Math.abs(this.y - other.y) < tolerance &&
      Math.abs(this.z - other.z) < tolerance
    );
  }
}

/**
 * Represents the position and orientation (pose) of an object in 3D space.
 */
class Pose {
  /**
   * A zero pose (origin with no rotation)
   * @type {Pose}
   */
  static ZERO = new Pose(Point3D.ZERO, new Matrix3x3());
  /**
   * Creates an instance of Pose.
   * @param {Point3D} [point] - The position of the object. Defaults to (0,0,0).
   * @param {Matrix3x3} [rotationMatrix] - The orientation of the object. Defaults to an identity matrix.
   */
  constructor(point, rotationMatrix) {
    this.point = point || Point3D.ZERO;
    this.rotation = rotationMatrix || new Matrix3x3();
  }

  /**
   * Moves the pose by a given offset.
   * @param {number} x - The offset in the x-direction.
   * @param {number} y - The offset in the y-direction.
   * @param {number} z - The offset in the z-direction.
   * @returns {Pose} A new Pose instance with the updated position.
   */
  move(x, y, z) {
    return new Pose(this.point.move(x, y, z), this.rotation);
  }

  /**
   * Rotates the pose by a given rotation matrix.
   * @private
   * @param {Matrix3x3} rotationMatrix - The rotation matrix to apply.
   * @returns {Pose} A new Pose instance with the updated orientation and position.
   */
  _rotate(rotationMatrix) {
    const newRotation = rotationMatrix.multiply(this.rotation);
    const newPoint = this.point.transform(rotationMatrix);
    return new Pose(newPoint, newRotation);
  }

  /**
   * Rotates the pose around the X-axis.
   * @param {number} d - The rotation angle in degrees.
   * @returns {Pose} A new Pose instance with the updated orientation.
   */
  rotateX(d) {
    return this._rotate(Matrix3x3.rotationX(d));
  }

  /**
   * Rotates the pose around the Y-axis.
   * @param {number} d - The rotation angle in degrees.
   * @returns {Pose} A new Pose instance with the updated orientation.
   */
  rotateY(d) {
    return this._rotate(Matrix3x3.rotationY(d));
  }

  /**
   * Rotates the pose around the Z-axis.
   * @param {number} d - The rotation angle in degrees.
   * @returns {Pose} A new Pose instance with the updated orientation.
   */
  rotateZ(d) {
    return this._rotate(Matrix3x3.rotationZ(d));
  }

  /**
   * Checks if this pose is equal to another pose.
   * @param {Pose} other - The pose to compare with.
   * @returns {boolean} True if the poses are equal, false otherwise.
   */
  equals(other) {
    if (!other || !(other instanceof Pose)) {
      return false;
    }
    return this.point.equals(other.point) && this.rotation.equals(other.rotation);
  }
}

/**
 * Applies a pose to a CadObjectM, transforming its position and orientation.
 * @param {CadObjectM} cadobject - The object to be placed.
 * @param {Pose} pose - The target pose (position and orientation).
 * @returns {CadObjectM} The transformed CadObjectM.
 */
function place(cadobject, pose) {
  const angles = pose.rotation.toEulerAngles();

  // The order of rotation is important. We assume a Z-Y-X order here,
  // which corresponds to yaw, pitch, and roll.
  const rotatedObject = cadobject
    .rotateZ(angles.yaw)
    .rotateY(angles.pitch)
    .rotateX(angles.roll);

  const movedObject = rotatedObject.move(pose.point.x, pose.point.y, pose.point.z);

  return movedObject;
}


const CadObjects = [];
let Transform = (o)=>o;

function main() {
  return CadObjects.map(o=>{
    if (o instanceof Function) o = o();
    if (o.emptyp()) return {};
    return {
      shape: Transform(o).shape(),
      color: o.color() || _genRandomColor(),
      name: o.name(),
      opacity: o.opacity(),
    };
  })
}

function define(o) {
  var {
    name,
    obj,
    fn,
    output=DEFAULT
  } = o;
  if (!obj) {
    if (!fn) {
      fn = eval(name);
    }
  } else {
    fn = ()=>obj;
  }
  if (!name) {
    name = "obj_" + define.num;
    define.num++;
  }
  if (output) {
    o = fn();
    o._name = name;
    CadObjects.push(o);
  }
}
define.num = 0;

// Finder

function addCombinator(fn) {
  fn.and = function(fn2) {
    return addCombinator(function(f) {
      return fn2(fn(f));
    })
  }
  fn.not = function() {
    return addCombinator(function(f) {
      return f.not(fn);
    })
  }
  return fn
}

function inPlane(plane, distance = 0) {
  return addCombinator(function(f){
    return f.inPlane(plane, distance)
  })
}

const inXY = inPlane("XY");
const inXZ = inPlane("XZ");
const inYZ = inPlane("YZ");

function atAngleWith(axis) {
  return addCombinator(function (f) {
    return f.atAngleWith(axis)
  })
}

const atX = atAngleWith("X");
const atY = atAngleWith("Y");
const atZ = atAngleWith("Z");

// 2d code

const codesize = 6;
const cell_size = 2;

function code(data) {

  function dot(){
    return (box(cell_size,cell_size,0.2))
  }

  let rv = empty();
  let digit = 1;

  for (let x=0;x<codesize;x++){
    for (let y=0;y<codesize;y++){
      let cell = 0;
      if (marker[y*codesize+x]==2) {
        if ((data & digit) != 0) {
          cell = 1;
        }
        digit <<= 1;
      } else if(marker[y*codesize+x]==1) {
        cell = 1;
      }
      if (cell==1) {
        rv = rv.union(dot().move((2+x)*cell_size,(2+y)*cell_size,0));
      }
    }
  }

  return rv;
}

// 36個の点がある。
// 端の1はマーカーにする。36-4=32

var marker = [
  1,2,2,2,2,1,
  2,2,2,2,2,2,
  2,2,2,2,2,2,
  2,2,2,2,2,2,
  2,2,2,2,2,2,
  1,2,2,2,2,1,
];

const addCheckDigit8 = (input)=>{
  // Input int24 0-16777216
  // Output int24 + alder8
  const BASE = 13
  let tmp = input;
  let inl = [];
  for (let i=0;i<6;i++) {
    inl.unshift(tmp & 0xf);
    tmp >>= 4;
  }
  let a = 1;
  let b = 0;
  for (let i=0;i<6;i++) {
    a += inl[i];
    a = a % BASE;
    b += a;
    b = b % BASE;
  }
  // console.log([input, a, b, input*256+ (a << 4) + b]);
  return (input * 256) + (a << 4) + b;
};


const addCheckDigit16 = (input)=>{
  // Input int16 0-65535
  // Output int16 + alder16
  const BASE = 251
  let tmp = input;
  let inl = [];
  for (let i=0;i<2;i++) {
    inl.unshift(tmp & 0xff);
    tmp >>= 8;
  }
  let a = 1;
  let b = 0;
  for (let i=0;i<2;i++) {
    a += inl[i];
    a = a % BASE;
    b += a;
    b = b % BASE;
  }
  // console.log([
  //   input, a, b, input*256*256 + (a << 8) + b]);
  return (input * 256 * 256) + (a << 8) + b;
};

// const addCheckDigit = addCheckDigit16;
// const checkDigitBitsLen = 16;
const addCheckDigit = addCheckDigit8;
const checkDigitBitsLen = 8;

/* Example

defineCadObject("code",
  code(addCheckDigit(999)).move(5,5,0))

*/

// Calc

function range(n) {
  var rv = [];
  for (var i=0;i<n;i++) {
    rv.push(i);
  }
  return rv;
}

/// }}}
// User Code 

// define({name: "code",  // {{{
//   fn: ()=>
//   code(addCheckDigit(20)).move(5,5,0)
// })  // }}}

define({name: "case",  // {{{
  fn: ()=> {
    const 外形高 = 23
    const 外形寸法 = 110
    const 外形 = box(外形寸法,外形寸法,外形高).move(-外形寸法/2,-外形寸法/2,0).fillet(12.5, atZ);
    const 蓋寸法 = 101
    const 蓋 = box(蓋寸法, 蓋寸法+100,2).move(-蓋寸法/2,-蓋寸法/2,外形高-6).fillet(10, atZ);
    const 開口寸法 = 蓋寸法;
    const 開口 = box(開口寸法, 開口寸法+100, 5)
      .move(-開口寸法/2, -開口寸法/2, 外形高-5)
      .fillet(8, atZ)
      .chamfer(4, f=>f.inPlane("XY", 外形高))
    const 内側 = box(91,91,40).move(-91/2,-91/2,3)
    const USB = box(20, 1000, 20).move(-10+30,30,3+1+1.6+3)
    const トップノッチ = box(10, 5-0.5, 2).move(-5,蓋寸法/2,外形高-6)
    const 基板台 =()=>cylinder(8, 2).move(0,0,3).cut(cylinder(2,2))
    const 基板台群 = union([
      基板台().move(-(90/2-5),-(90/2-5),0),
      基板台().move( (90/2-5),-(90/2-5),0),
      基板台().move( (90/2-5), (90/2-5),0),
      基板台().move(-(90/2-5), (90/2-5),0),
    ])
    const 基板固定突起部 = ()=>
      box(2,10,10)
      .move(45.5,-5,3)
    const 突起長 = 6
    const 基板固定突起 = ()=>
      box(1,10,突起長)
      .move(0,0,-突起長)
      .asymmetricChamfer(atX.and(inXY), inXY,3,突起長-1)
      .move(0,0,突起長)
      .union(
        box(1,4,2)
        .chamfer(0.99, atY.and(inYZ))
        .move(-1,3,6-3)
      )
      .move(45.5,-5,3)
    return 外形
      .cut(蓋)
      .cut(内側)
      .cut(開口)
      .union(基板台群)
      .cut(USB)
      .cut(基板固定突起部())
      .union(基板固定突起())
      .cut(基板固定突起部().mirrorX())
      .union(基板固定突起().mirrorX())
      .union(トップノッチ)
  }
})  // }}}

define({name: "pcb",  // {{{
  // output: false,
  fn: ()=> {
    const 外形 = box(90,90,1.5).move(-45,-45,3+2);
    return 外形
  }
})  // }}}

// vim: set fdm=marker :
