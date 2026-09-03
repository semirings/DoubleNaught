/// Node width registry — single source of truth for port anchoring.
/// Maps node type string to rendered width (pixels).
/// Used by workflow_page.dart's _nodeWidthFor() to position edge connectors.
///
/// TODO: Convert to using static constants from each node implementation once
/// all nodes export `static const double kNodeWidth`. For now, values are
/// hardcoded here with references to their node implementations.

// ignore: avoid_relative_lib_imports
import '../../models/node_group.dart';

/// Get node width by type, with standard default (240px).
/// Ensures edges anchor at port connectors, not inside node bounds.
double getNodeWidth(String type) {
  switch (type) {
    // D4M and related scripting
    case 'd4m':
      return 340; // D4mNode._width
    case 'secureSettingsNode':
      return 300; // SecureSettingsNode: @override double get nodeWidth => 300
    case 'promptNode':
      return 320; // PromptNodeWidget._width

    // Execution nodes
    case 'polyglotExecNode':
      return 320;
    case 'jsonlFormatterNode':
      return 320;
    case 'functionExtractionNode':
      return 320;
    case 'llmDocumenterNode':
      return 320;

    // Model-related
    case 'inventory':
      return 320; // InventoryNode._width
    case 'review':
      return 320; // ReviewNode._width
    case 'load_model':
      return 320; // LoadModelNode._width
    case 'model_classifier':
      return 320; // ModelClassifierNode._width
    case 'model_builder':
      return 320; // ModelBuilderNode._width
    case 'text_model_loader':
      return 320; // TextModelLoaderNode._width

    // Text processing
    case 'text_prompt':
      return 320; // TextPromptNode._width
    case 'text_inference':
      return 320; // TextInferenceNode._width

    // Categories and grouping
    case 'categories':
      return 300; // CategoriesNode._width
    case NodeGroup.type: // 'nodeGroup'
      return 260;

    // File I/O
    case 'save_file':
      return 320;

    // Standard width (240px)
    default:
      return 240;
  }
}
