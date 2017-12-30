// Copyright (c) .NET Foundation. All rights reserved.
// Licensed under the Apache License, Version 2.0. See License.txt in the project root for license information.

using System.Collections.Generic;
using System.IO;
using System.Xml;
using Microsoft.Build.Framework;
using Microsoft.Build.Utilities;

namespace RepoTasks
{
    public class ComposeNewStore : Task
    {
        [Required]
        public ITaskItem[] ExistingManifests { get; set; }

        [Required]
        public ITaskItem[] NewManifests { get; set; }

        public ITaskItem[] RuntimeStoreFiles { get; set; }

        public ITaskItem[] RuntimeStoreSymbolFiles { get; set; }

        [Required]
        public string ManifestDestination { get; set; }

        public string StoreDestination { get; set; }

        public string SymbolsDestination { get; set; }

        public override bool Execute()
        {
            var existingFiles = new Dictionary<string, HashSet<string>>();
            var newRuntimeStoreFiles = new List<ITaskItem>();
            var newRuntimeStoreSymbolFiles = new List<ITaskItem>();

            // Construct database of existing assets
            foreach (var manifest in ExistingManifests)
            {
                var xmlDoc = new XmlDocument();
                xmlDoc.Load(manifest.GetMetadata("FullPath"));
                var storeArtifacts = xmlDoc.SelectSingleNode("/StoreArtifacts");

                foreach (XmlNode artifact in storeArtifacts.ChildNodes)
                {
                    if (existingFiles.TryGetValue(artifact.Attributes["Id"].Value, out var versions))
                    {
                        versions.Add(artifact.Attributes["Version"].Value);
                    }
                    else
                    {
                        existingFiles[artifact.Attributes["Id"].Value] = new HashSet<string>{ artifact.Attributes["Version"].Value };
                    }
                }
            }

            if (RuntimeStoreFiles != null)
            {
                // Insert new runtime store files
                foreach (var storeFile in RuntimeStoreFiles)
                {
                    // format: {bitness}}/{tfm}}/{id}/{version}}/...
                    var recursiveDir = storeFile.GetMetadata("RecursiveDir");
                    var components = recursiveDir.Split(Path.DirectorySeparatorChar);
                    var id = components[2];
                    var version = components[3];

                    if (!existingFiles.TryGetValue(id, out var versions) || !versions.Contains(version))
                    {
                        var destinationDir = Path.Combine(StoreDestination, recursiveDir);
                        if (!Directory.Exists(Path.Combine(StoreDestination, recursiveDir)))
                        {
                            Directory.CreateDirectory(destinationDir);
                        }

                        File.Copy(storeFile.GetMetadata("FullPath"), Path.Combine(destinationDir, $"{storeFile.GetMetadata("Filename")}{storeFile.GetMetadata("Extension")}"), overwrite: true);
                    }
                }
            }

            if (RuntimeStoreSymbolFiles != null)
            {
                // Insert new runtime store symbol files
                foreach (var symbolFile in RuntimeStoreSymbolFiles)
                {
                    // format: {bitness}}/{tfm}}/{id}/{version}}/...
                    var recursiveDir = symbolFile.GetMetadata("RecursiveDir");
                    var components = recursiveDir.Split(Path.DirectorySeparatorChar);
                    var id = components[2];
                    var version = components[3];

                    if (!existingFiles.TryGetValue(id, out var versions) || !versions.Contains(version))
                    {
                        var destinationDir = Path.Combine(SymbolsDestination, recursiveDir);
                        if (!Directory.Exists(Path.Combine(SymbolsDestination, recursiveDir)))
                        {
                            Directory.CreateDirectory(destinationDir);
                        }

                        File.Copy(symbolFile.GetMetadata("FullPath"), Path.Combine(destinationDir, $"{symbolFile.GetMetadata("Filename")}{symbolFile.GetMetadata("Extension")}"), overwrite: true);
                    }
                }
            }

            // Purge existing packages from manifest
            foreach (var newManifest in NewManifests)
            {
                var newManifestPath = newManifest.GetMetadata("FullPath");
                var xmlDoc = new XmlDocument();
                xmlDoc.Load(newManifestPath);
                var storeArtifacts = xmlDoc.SelectSingleNode("/StoreArtifacts");
                var artifactsToRemove = new List<XmlNode>();

                foreach (XmlNode artifact in storeArtifacts.ChildNodes)
                {
                    if (existingFiles.TryGetValue(artifact.Attributes["Id"].Value, out var versions) && versions.Contains(artifact.Attributes["Version"].Value))
                    {
                        artifactsToRemove.Add(artifact);
                    }
                }

                foreach (var artifactToRemove in artifactsToRemove)
                {
                    storeArtifacts.RemoveChild(artifactToRemove);
                }

                xmlDoc.Save(ManifestDestination);
            }

            return true;
        }
    }
}
