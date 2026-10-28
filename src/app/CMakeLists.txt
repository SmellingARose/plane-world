find_package(Qt6 6.8 REQUIRED COMPONENTS Quick QuickControls2)
qt_standard_project_setup(REQUIRES 6.8)

# Sources and QML are globbed so the BUILD / FLY (P5a) and WORLD / EVOLVE (P5b) work can add files independently.
file(GLOB PW_APP_SOURCES CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/*.cpp ${CMAKE_CURRENT_SOURCE_DIR}/*.h)
file(GLOB PW_APP_QML RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/qml/*.qml ${CMAKE_CURRENT_SOURCE_DIR}/qml/*.js)
qt_add_executable(pwapp MACOSX_BUNDLE WIN32 ${PW_APP_SOURCES})
if(APPLE)
  target_sources(pwapp PRIVATE gpuviewport_metal.mm)
  set_source_files_properties(gpuviewport_metal.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
endif()
set_target_properties(pwapp PROPERTIES
  OUTPUT_NAME "Plane World"
  MACOSX_BUNDLE_GUI_IDENTIFIER org.planeworld.app
  MACOSX_BUNDLE_BUNDLE_NAME "Plane World"
  MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
  MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION})

set_source_files_properties(qml/Theme.qml qml/WorldTools.qml qml/WorldFlow.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
qt_add_qml_module(pwapp
  URI PlaneWorld
  VERSION 1.0
  QML_FILES ${PW_APP_QML}
)
target_link_libraries(pwapp PRIVATE Qt6::Quick Qt6::QuickControls2 pwcore pwgpu pwrender pwenv pwenv_render)   # pwenv: WORLD (P5b)

if(WIN32)
  # Deploy Qt next to the exe for CI artefacts (windeployqt from the same Qt install).
  get_target_property(_qmake Qt6::qmake IMPORTED_LOCATION)
  get_filename_component(_qtbin ${_qmake} DIRECTORY)
  find_program(PW_WINDEPLOYQT windeployqt HINTS ${_qtbin})
  if(PW_WINDEPLOYQT)
    # Self-contained folder: ${CMAKE_BINARY_DIR}/deploy/Plane World.exe + Qt runtime (no build intermediates).
    # The MSVC runtime DLLs go next to the exe (app-local), so a PC without the VC++ Redistributable still starts it;
    # windeployqt would only copy vc_redist.x64.exe, which nothing runs.
    set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP TRUE)
    include(InstallRequiredSystemLibraries)
    if(MSVC AND NOT CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS)
      message(WARNING "MSVC runtime DLLs not found: the deploy folder will need the VC++ Redistributable installed")
    endif()
    set(_dep ${CMAKE_BINARY_DIR}/deploy)
    add_custom_target(pwapp_deploy
      COMMAND ${CMAKE_COMMAND} -E rm -rf ${_dep}
      COMMAND ${CMAKE_COMMAND} -E make_directory ${_dep}
      COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:pwapp> ${CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS} ${_dep}/
      COMMAND ${PW_WINDEPLOYQT} --qmldir ${CMAKE_CURRENT_SOURCE_DIR}/qml --no-translations --no-compiler-runtime "${_dep}/$<TARGET_FILE_NAME:pwapp>"
      DEPENDS pwapp VERBATIM)
  endif()
elseif(APPLE)
  get_target_property(_qmake Qt6::qmake IMPORTED_LOCATION)
  get_filename_component(_qtbin ${_qmake} DIRECTORY)
  find_program(PW_MACDEPLOYQT macdeployqt HINTS ${_qtbin})
  if(PW_MACDEPLOYQT)
    add_custom_target(pwapp_deploy
      COMMAND ${PW_MACDEPLOYQT} $<TARGET_BUNDLE_DIR:pwapp> -qmldir=${CMAKE_CURRENT_SOURCE_DIR}/qml
      DEPENDS pwapp VERBATIM)
  endif()
endif()

# P5b: WORLD / EVOLVE view-model tests (no window; QT_QPA_PLATFORM=offscreen).
if(PW_BUILD_TESTS)
  qt_add_executable(pwuitests ${PROJECT_SOURCE_DIR}/tests/test_ui.cpp
    worldmodel.cpp worldmodel.h evolvemodel.cpp evolvemodel.h jshighlighter.cpp jshighlighter.h replayprovider.h)
  set_target_properties(pwuitests PROPERTIES MACOSX_BUNDLE OFF WIN32_EXECUTABLE OFF)
  target_include_directories(pwuitests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  target_compile_definitions(pwuitests PRIVATE PW_QML_DIR="${CMAKE_CURRENT_SOURCE_DIR}/qml")
  target_link_libraries(pwuitests PRIVATE Qt6::Quick pwcore pwgpu pwenv)
  add_test(NAME pwuitests COMMAND pwuitests)
endif()
