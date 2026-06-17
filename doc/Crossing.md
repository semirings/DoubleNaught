Visual → Semantic
    image to caption
    SAM3 label assignment
    
Semantic → Stroke
    caption to GP drawing instructions
    
Visual → Stroke
    segment mask to GP trace
    
Stroke → Geometric
    GP strokes to 3D mesh
    
Geometric → Topological
    raw mesh to animation-ready mesh
    
Visual → Correspondence
    SAM3 output to D4M associative array
    
Correspondence → Semantic
    D4M query results to JSONL captions