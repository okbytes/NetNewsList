var SafariExtPreprocessorClass = function() {};

SafariExtPreprocessorClass.prototype = {
    
    run: function(arguments) {
        arguments.completionFunction({ "url": document.URL, "title": document.title });
    } 
    
};

// The JavaScript file must contain a global object named "ExtensionPreprocessingJS".
var ExtensionPreprocessingJS = new SafariExtPreprocessorClass;
