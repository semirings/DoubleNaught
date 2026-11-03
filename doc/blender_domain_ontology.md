name: blender_ontology
id: https://w3id.org/dn/blender-ontology
description: >-
  LinkML domain ontology for programmatically controlling Blender via bpy and headless scripts.
  Serves as the source-of-truth for compiling Blender scene specifications into D4M Associative Arrays
  and context-engineered LLM/SLM execution payloads.

prefixes:
  linkml: https://w3id.org/linkml/
  bo: https://w3id.org/dn/blender-ontology#

default_prefix: bo

imports:
  - linkml:types

subsets:
  Topology:
    description: Geometry primitives, mesh operations, modifier stacks, and procedural node trees.
  Material:
    description: Surface shaders, non-photorealistic (NPR) rendering styles, line-art, and color palettes.
  Stage:
    description: Spatial positioning, cameras, lighting setups, and animation/rigging constraints.
  Pipeline:
    description: Headless execution args, render engine flags, output passes, and compositor settings.

classes:

  BlenderEntity:
    description: Abstract base class for all programmatic Blender scene objects and configurations.
    abstract: true

  # ==========================================
  # TOPOLOGY SUBSET
  # ==========================================

  MeshEntity:
    is_a: BlenderEntity
    description: "A 3D polygonal mesh object in the Blender scene."
    in_subset:
      - Topology
    annotations:
      rule: "All mesh transformations should be explicitly applied before binding to armatures."
    slots:
      - name
      - primitive_type
      - is_procedural
      - active_modifiers
      - geometry_node_tree
    slot_usage:
      name:
        required: true

  Modifier:
    is_a: BlenderEntity
    description: "An entry in an object's modifier stack."
    in_subset:
      - Topology
    slots:
      - modifier_type
      - execution_order
      - parameters
    slot_usage:
      modifier_type:
        required: true

  GeometryNodeGraph:
    is_a: BlenderEntity
    description: "A procedural Geometry Nodes modifier graph."
    in_subset:
      - Topology
    slots:
      - graph_name
      - inputs
      - outputs

  # ==========================================
  # MATERIAL & SHADER SUBSET
  # ==========================================

  MaterialSlot:
    is_a: BlenderEntity
    description: "A material assignment slot on a mesh or curve object."
    in_subset:
      - Material
    slots:
      - slot_index
      - bound_material
    slot_usage:
      slot_index:
        required: true
      bound_material:
        required: true

  ToonShader:
    is_a: BlenderEntity
    description: "A non-photorealistic toon shader graph with quantized lighting steps."
    in_subset:
      - Material
    annotations:
      rule: "Must enforce backface culling when used with ink outline shell setups."
    slots:
      - shader_name
      - quantization_levels
      - line_art_enabled
      - palette_constraints

  LineArtPass:
    is_a: BlenderEntity
    description: "Freestyle or Grease Pencil line-art outline generator configuration."
    in_subset:
      - Material
    slots:
      - line_thickness
      - stroke_color
      - edge_detection_mode

  # ==========================================
  # STAGE & CAMERA SUBSET
  # ==========================================

  TransformNode:
    is_a: BlenderEntity
    description: "Spatial coordinates, rotations, and scales for scene objects."
    in_subset:
      - Stage
    slots:
      - location
      - rotation_euler
      - scale

  CameraRig:
    is_a: BlenderEntity
    description: "A camera object and its associated track-to or framing setup."
    in_subset:
      - Stage
    slots:
      - camera_name
      - focal_length
      - sensor_width
      - constraint_target

  LightStage:
    is_a: BlenderEntity
    description: "Illumination sources setup for the scene."
    in_subset:
      - Stage
    slots:
      - light_type
      - energy
      - color_temperature

  # ==========================================
  # PIPELINE & RENDER SUBSET
  # ==========================================

  RenderPassConfig:
    is_a: BlenderEntity
    description: "Selection of AOVs, depth maps, and normal passes exported per render."
    in_subset:
      - Pipeline
    annotations:
      rule: "NCM training dataset generations must export Normal and Depth passes alongside RGB."
    slots:
      - export_rgb
      - export_depth
      - export_normal
      - export_segmentation_id

  BatchRenderJob:
    is_a: BlenderEntity
    description: "Headless execution configuration for `blender -b -P` batch processes."
    in_subset:
      - Pipeline
    slots:
      - render_engine
      - sample_count
      - output_directory
      - output_format

# ==========================================
# SLOTS
# ==========================================

slots:

  # General Properties
  name:
    range: string
    description: "Identifier name for the Blender datablock (bpy.data.*)."

  # Topology Slots
  primitive_type:
    range: PrimitiveTypeEnum
  is_procedural:
    range: boolean
  active_modifiers:
    range: Modifier
    multivalued: true
  geometry_node_tree:
    range: GeometryNodeGraph
  modifier_type:
    range: ModifierTypeEnum
  execution_order:
    range: integer
  parameters:
    range: string
  graph_name:
    range: string
  inputs:
    range: string
    multivalued: true
  outputs:
    range: string
    multivalued: true

  # Material Slots
  slot_index:
    range: integer
  bound_material:
    range: ToonShader
  shader_name:
    range: string
  quantization_levels:
    range: integer
  line_art_enabled:
    range: boolean
  palette_constraints:
    range: string
    multivalued: true
  line_thickness:
    range: float
  stroke_color:
    range: string
  edge_detection_mode:
    range: string

  # Stage Slots
  location:
    range: float
    multivalued: true
    description: "3D vector [X, Y, Z]."
  rotation_euler:
    range: float
    multivalued: true
    description: "Euler rotation vector [X, Y, Z] in radians."
  scale:
    range: float
    multivalued: true
    description: "3D scale vector [X, Y, Z]."
  camera_name:
    range: string
  focal_length:
    range: float
  sensor_width:
    range: float
  constraint_target:
    range: string
  light_type:
    range: LightTypeEnum
  energy:
    range: float
  color_temperature:
    range: float

  # Pipeline Slots
  export_rgb:
    range: boolean
  export_depth:
    range: boolean
  export_normal:
    range: boolean
  export_segmentation_id:
    range: boolean
  render_engine:
    range: RenderEngineEnum
  sample_count:
    range: integer
  output_directory:
    range: string
  output_format:
    range: string

# ==========================================
# ENUMS
# ==========================================

enums:

  PrimitiveTypeEnum:
    permissible_values:
      CUBE:
      UV_SPHERE:
      CYLINDER:
      MONKEY:
      EMPTY:
      CURVE_BEZIER:

  ModifierTypeEnum:
    permissible_values:
      ARMATURE:
      BOOLEAN:
      GEOMETRY_NODES:
      SOLIDIFY:
      SUBSURF:
      SMOOTH:

  LightTypeEnum:
    permissible_values:
      POINT:
      SUN:
      SPOT:
      AREA:

  RenderEngineEnum:
    permissible_values:
      BLENDER_EEVEE_NEXT:
      CYCLES:
      WORKBENCH: